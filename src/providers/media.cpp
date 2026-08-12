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

class MediaProviderImpl {
public:
    MediaProvider* facade = nullptr;
    GlobalSystemMediaTransportControlsSessionManager manager{nullptr};
    GlobalSystemMediaTransportControlsSession session{nullptr};
    winrt::event_token sessionsToken{};
    winrt::event_token propertiesToken{};
    winrt::event_token playbackToken{};
    MediaEnvironment cached;
    mutable std::mutex mutex;
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
    // CurrentSessionChanged re-attach, so every touch of `session` is guarded.
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
        detachSession();
        if (!manager) return;
        session = manager.GetCurrentSession();
        if (!session) {
            publish({}); // nothing playing
            return;
        }
        propertiesToken = session.MediaPropertiesChanged(
            [this](auto&&, auto&&) { publishFromSession(); });
        playbackToken =
            session.PlaybackInfoChanged([this](auto&&, auto&&) { publishFromSession(); });
        publishFromSession();
    }

    void publishFromSession() {
        std::lock_guard<std::recursive_mutex> lock(sessionMutex);
        if (!session) return;
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
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (env == cached) return; // deduped
            cached = env;
        }
        if (facade && facade->onChange) facade->onChange(env);
    }
};

MediaProvider::MediaProvider() : impl_(std::make_unique<MediaProviderImpl>()) {
    impl_->facade = this;
}

MediaProvider::~MediaProvider() { stop(); }

bool MediaProvider::start() {
    if (impl_->running) return true;
    auto* impl = impl_.get();
    impl->stopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!impl->stopEvent) return false;

    impl->worker = std::thread([impl] {
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
        bool ok = false;
        try {
            impl->manager =
                GlobalSystemMediaTransportControlsSessionManager::RequestAsync().get();
            if (impl->manager) {
                impl->sessionsToken = impl->manager.CurrentSessionChanged(
                    [impl](auto&&, auto&&) { impl->attachCurrentSession(); });
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
        if (!ok) return;

        // Park until stop(): the event handlers fire on WinRT threadpool
        // threads, so this thread exists only to own the MTA and the
        // registrations.
        WaitForSingleObject(impl->stopEvent, INFINITE);
        impl->detachSession();
        if (impl->manager && impl->sessionsToken)
            impl->manager.CurrentSessionChanged(impl->sessionsToken);
        impl->manager = nullptr;
        winrt::uninit_apartment();
    });

    std::unique_lock<std::mutex> lock(impl->readyMutex);
    impl->ready.wait(lock, [impl] { return impl->started; });
    const bool ok = impl->startResult;
    lock.unlock();
    if (!ok) {
        impl->worker.join();
        CloseHandle(impl->stopEvent);
        impl->stopEvent = nullptr;
        return false;
    }
    impl->running = true;
    return true;
}

void MediaProvider::stop() {
    if (!impl_ || !impl_->running) return;
    impl_->stopping = true;
    SetEvent(impl_->stopEvent);
    if (impl_->worker.joinable()) impl_->worker.join();
    CloseHandle(impl_->stopEvent);
    impl_->stopEvent = nullptr;
    impl_->running = false;
}

const MediaEnvironment& MediaProvider::current() const {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    return impl_->cached;
}

bool MediaProvider::refresh() {
    if (!impl_->running && !start()) return false;
    // Replay the cached env unconditionally (spec 10: reload mid-song must
    // restore the now-playing pill).
    MediaEnvironment env;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        env = impl_->cached;
    }
    if (onChange) onChange(env);
    return true;
}

} // namespace ybar::providers
