#include "providers/media.h"

// clang-format off
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.Control.h>
// clang-format on

#include <atomic>
#include <condition_variable>
#include <cstdio>
#include <mutex>
#include <thread>

namespace ybar::providers {

namespace {

using namespace winrt::Windows::Media::Control;

std::string narrow(const winrt::hstring& text) {
    if (text.empty()) return {};
    const int size = WideCharToMultiByte(CP_UTF8, 0, text.c_str(),
                                         static_cast<int>(text.size()), nullptr, 0, nullptr,
                                         nullptr);
    std::string out(static_cast<std::size_t>(size), '\0');
    WideCharToMultiByte(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()), out.data(),
                        size, nullptr, nullptr);
    return out;
}

// Reference publishes lowercase states ("playing"/"paused"/...).
std::string stateName(GlobalSystemMediaTransportControlsSessionPlaybackStatus status) {
    switch (status) {
        case GlobalSystemMediaTransportControlsSessionPlaybackStatus::Playing: return "playing";
        case GlobalSystemMediaTransportControlsSessionPlaybackStatus::Paused: return "paused";
        case GlobalSystemMediaTransportControlsSessionPlaybackStatus::Stopped: return "stopped";
        case GlobalSystemMediaTransportControlsSessionPlaybackStatus::Changing: return "changing";
        case GlobalSystemMediaTransportControlsSessionPlaybackStatus::Opened: return "opened";
        default: return "closed";
    }
}

} // namespace

// Lifetime: MediaProvider holds the owning shared_ptr; every WinRT event
// handler captures a weak_ptr and promotes it on entry, so an in-flight
// handler keeps the impl alive through teardown, and a handler that fires
// after teardown finds either an expired weak_ptr or `stopping` set — never
// freed memory or a destroyed mutex.
class MediaProviderImpl : public std::enable_shared_from_this<MediaProviderImpl> {
public:
    GlobalSystemMediaTransportControlsSessionManager manager{nullptr};
    GlobalSystemMediaTransportControlsSession session{nullptr};
    winrt::event_token sessionsToken{};
    winrt::event_token propertiesToken{};
    winrt::event_token playbackToken{};
    MediaEnvironment cached;
    // Copied from the facade at start() and cleared at stop() so a late
    // handler can never call through a destroyed MediaProvider.
    std::function<void(const MediaEnvironment&)> onChange;
    mutable std::mutex mutex; // guards cached + onChange
    bool running = false;

    // The daemon's UI thread is an STA (WIC requires it), and every GSMTC
    // entry point here blocks on an IAsyncOperation — which deadlocks an STA.
    // So the whole provider lives on its own MTA thread.
    std::thread worker;
    std::mutex readyMutex;
    std::condition_variable ready;
    bool started = false;
    bool startResult = false;
    std::atomic<bool> stopping{false};
    HANDLE stopEvent = nullptr;

    // Session handlers arrive on WinRT threadpool threads and can overlap a
    // CurrentSessionChanged re-attach, so every touch of `session`/`manager`
    // is guarded, and every guarded entry re-checks `stopping`.
    std::recursive_mutex sessionMutex;

    void detachSession() {
        std::lock_guard<std::recursive_mutex> lock(sessionMutex);
        if (!session) return;
        if (propertiesToken) session.MediaPropertiesChanged(propertiesToken);
        if (playbackToken) session.PlaybackInfoChanged(playbackToken);
        propertiesToken = {};
        playbackToken = {};
        session = nullptr;
    }

    void attachCurrentSession() {
        std::lock_guard<std::recursive_mutex> lock(sessionMutex);
        if (stopping) return;
        detachSession();
        if (!manager) return;
        session = manager.GetCurrentSession();
        if (!session) {
            publish({}); // nothing playing
            return;
        }
        std::weak_ptr<MediaProviderImpl> weak = weak_from_this();
        propertiesToken = session.MediaPropertiesChanged([weak](auto&&, auto&&) {
            if (auto self = weak.lock()) self->publishFromSession();
        });
        playbackToken = session.PlaybackInfoChanged([weak](auto&&, auto&&) {
            if (auto self = weak.lock()) self->publishFromSession();
        });
        publishFromSession();
    }

    void publishFromSession() {
        std::lock_guard<std::recursive_mutex> lock(sessionMutex);
        if (stopping || !session) return;
        MediaEnvironment env;
        try {
            const auto info = session.GetPlaybackInfo();
            env["MEDIA_STATE"] = info ? stateName(info.PlaybackStatus()) : "closed";
            env["MEDIA_APP"] = narrow(session.SourceAppUserModelId());
            // TryGetMediaPropertiesAsync is async; get() is safe here because
            // we are already on a WinRT worker thread, never the UI thread.
            const auto properties = session.TryGetMediaPropertiesAsync().get();
            if (properties) {
                env["MEDIA_TITLE"] = narrow(properties.Title());
                env["MEDIA_ARTIST"] = narrow(properties.Artist());
                env["MEDIA_ALBUM"] = narrow(properties.AlbumTitle());
            }
        } catch (const winrt::hresult_error&) {
            return; // a session can vanish mid-query
        }
        publish(env);
    }

    void publish(MediaEnvironment env) {
        std::function<void(const MediaEnvironment&)> callback;
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (env == cached) return; // deduped
            cached = env;
            callback = onChange;
        }
        if (callback) callback(env);
    }
};

MediaProvider::MediaProvider() : impl_(std::make_shared<MediaProviderImpl>()) {}

MediaProvider::~MediaProvider() { stop(); }

bool MediaProvider::start() {
    if (impl_->running) return true;
    // A previous stop() (or failed start) leaves poison flags behind; a
    // restarted provider must not silently no-op every handler.
    impl_->stopping = false;
    impl_->started = false;
    impl_->startResult = false;
    impl_->stopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!impl_->stopEvent) return false;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        impl_->onChange = onChange;
    }

    // The worker owns only a weak reference too: if the provider is destroyed
    // while RequestAsync is still in flight, the thread must not resurrect it.
    std::weak_ptr<MediaProviderImpl> weak = impl_;
    impl_->worker = std::thread([weak] {
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
        auto impl = weak.lock();
        if (!impl) {
            winrt::uninit_apartment();
            return;
        }
        bool ok = false;
        try {
            impl->manager =
                GlobalSystemMediaTransportControlsSessionManager::RequestAsync().get();
            if (impl->manager) {
                impl->sessionsToken = impl->manager.CurrentSessionChanged([weak](auto&&,
                                                                                 auto&&) {
                    if (auto self = weak.lock()) self->attachCurrentSession();
                });
                impl->attachCurrentSession();
                ok = true;
            }
        } catch (const winrt::hresult_error& error) {
            std::fprintf(stderr, "[ybar] media provider unavailable (0x%08x)\n",
                         static_cast<unsigned>(error.code()));
        }
        {
            std::lock_guard<std::mutex> lock(impl->readyMutex);
            impl->started = true;
            impl->startResult = ok;
        }
        impl->ready.notify_all();
        if (!ok) {
            winrt::uninit_apartment();
            return;
        }

        // Park until stop(): the event handlers fire on WinRT threadpool
        // threads, so this thread exists only to own the MTA and the
        // registrations.
        WaitForSingleObject(impl->stopEvent, INFINITE);
        // stop() set `stopping` before signaling, so any handler entering a
        // sessionMutex-guarded section from here on is a no-op.
        if (impl->manager && impl->sessionsToken)
            impl->manager.CurrentSessionChanged(impl->sessionsToken);
        impl->detachSession();
        {
            std::lock_guard<std::recursive_mutex> lock(impl->sessionMutex);
            impl->manager = nullptr;
        }
        winrt::uninit_apartment();
    });

    std::unique_lock<std::mutex> lock(impl_->readyMutex);
    impl_->ready.wait(lock, [this] { return impl_->started; });
    const bool ok = impl_->startResult;
    lock.unlock();
    if (!ok) {
        impl_->worker.join();
        CloseHandle(impl_->stopEvent);
        impl_->stopEvent = nullptr;
        return false;
    }
    impl_->running = true;
    return true;
}

void MediaProvider::stop() {
    if (!impl_ || !impl_->running) return;
    impl_->stopping = true;
    {
        // A late handler must not call back into a MediaProvider that is
        // being destroyed.
        std::lock_guard<std::mutex> lock(impl_->mutex);
        impl_->onChange = nullptr;
    }
    SetEvent(impl_->stopEvent);
    if (impl_->worker.joinable()) impl_->worker.join();
    CloseHandle(impl_->stopEvent);
    impl_->stopEvent = nullptr;
    impl_->running = false;
}

MediaEnvironment MediaProvider::current() const {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    return impl_->cached;
}

bool MediaProvider::refresh() {
    if (!impl_->running && !start()) return false;
    MediaEnvironment env;
    std::function<void(const MediaEnvironment&)> callback;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        env = impl_->cached;
        callback = impl_->onChange;
    }
    // Reference guard (Daemon.swift forcedQueries["media_change"]): a bare
    // trigger before any session appeared dispatches nothing rather than an
    // empty media_change that widgets would read as "stopped". The trigger is
    // still intercepted — returning true keeps the plain bus fallback off.
    if (env.empty()) return true;
    if (callback) callback(env);
    return true;
}

} // namespace ybar::providers
