#include "providers/audio.h"

// clang-format off
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <mmdeviceapi.h>
#include <endpointvolume.h>
#include <wrl/client.h>
// clang-format on

#include <atomic>
#include <cmath>
#include <memory>
#include <mutex>

using Microsoft::WRL::ComPtr;

namespace ybar::providers {

namespace {

int percentFrom(IAudioEndpointVolume* volume) {
    if (!volume) return 0;
    BOOL muted = FALSE;
    if (SUCCEEDED(volume->GetMute(&muted)) && muted) return 0; // muted -> 0
    float scalar = 0;
    if (FAILED(volume->GetMasterVolumeLevelScalar(&scalar))) return 0;
    return static_cast<int>(std::lround(scalar * 100.0f));
}

} // namespace

// Volume/mute change callback. Lives as long as the provider; the daemon
// marshals to its UI thread inside onVolume.
class VolumeCallback final : public IAudioEndpointVolumeCallback {
public:
    explicit VolumeCallback(AudioProviderImpl* owner) : owner_(owner) {}

    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs_; }
    ULONG STDMETHODCALLTYPE Release() override {
        const ULONG remaining = --refs_;
        if (remaining == 0) delete this;
        return remaining;
    }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** object) override {
        if (riid == __uuidof(IUnknown) || riid == __uuidof(IAudioEndpointVolumeCallback)) {
            AddRef();
            *object = this;
            return S_OK;
        }
        *object = nullptr;
        return E_NOINTERFACE;
    }
    HRESULT STDMETHODCALLTYPE OnNotify(PAUDIO_VOLUME_NOTIFICATION_DATA data) override;

private:
    AudioProviderImpl* owner_;
    std::atomic<ULONG> refs_{1};
};

// Default-device changes: re-arm the volume listener on the new endpoint.
class DeviceCallback final : public IMMNotificationClient {
public:
    explicit DeviceCallback(AudioProviderImpl* owner) : owner_(owner) {}

    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs_; }
    ULONG STDMETHODCALLTYPE Release() override {
        const ULONG remaining = --refs_;
        if (remaining == 0) delete this;
        return remaining;
    }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** object) override {
        if (riid == __uuidof(IUnknown) || riid == __uuidof(IMMNotificationClient)) {
            AddRef();
            *object = this;
            return S_OK;
        }
        *object = nullptr;
        return E_NOINTERFACE;
    }
    HRESULT STDMETHODCALLTYPE OnDefaultDeviceChanged(EDataFlow flow, ERole role,
                                                     LPCWSTR) override;
    HRESULT STDMETHODCALLTYPE OnDeviceStateChanged(LPCWSTR, DWORD) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE OnDeviceAdded(LPCWSTR) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE OnDeviceRemoved(LPCWSTR) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE OnPropertyValueChanged(LPCWSTR, const PROPERTYKEY) override {
        return S_OK;
    }

private:
    AudioProviderImpl* owner_;
    std::atomic<ULONG> refs_{1};
};

class AudioProviderImpl {
public:
    AudioProvider* facade = nullptr;
    ComPtr<IMMDeviceEnumerator> enumerator;
    ComPtr<IAudioEndpointVolume> volume;
    ComPtr<VolumeCallback> volumeCallback;
    ComPtr<DeviceCallback> deviceCallback;
    int lastPercent = -1;
    bool running = false;
    // Volume and device-change callbacks arrive on different WASAPI threads.
    std::mutex publishMutex;
    // Serializes whole arm/teardown sequences (a device switch during start
    // runs two armEndpoint calls concurrently; unserialized, the loser's
    // control-change registration leaks with a dangling owner). Lock order:
    // armMutex before publishMutex, and never held while publishing.
    std::mutex armMutex;

    // Dedupe and dispatch a level that is already known. No COM call inside
    // the lock, and none at all: that is what makes this safe to run from a
    // WASAPI notification thread. onVolume is a PostMessage, so holding the
    // lock across it costs nothing and keeps two racing notifications in
    // order.
    void publishValue(int percent, bool forced) {
        std::lock_guard<std::mutex> lock(publishMutex);
        if (!forced && percent == lastPercent) return; // deduped (spec 10)
        lastPercent = percent;
        if (facade && facade->onVolume) facade->onVolume(percent);
    }

    // Reads the level from the endpoint, so it is for the daemon's own thread.
    // The endpoint is snapshotted under the lock and queried OUTSIDE it -- the
    // file rule setVolume() already follows. Holding publishMutex across a COM
    // call is what let a notification thread waiting on that same mutex sit
    // behind a message thread parked inside the audio service.
    void publish(bool forced) {
        ComPtr<IAudioEndpointVolume> endpoint;
        {
            std::lock_guard<std::mutex> lock(publishMutex);
            endpoint = volume;
        }
        publishValue(percentFrom(endpoint.Get()), forced);
    }

    // Called from the device-notification thread. Takes no lock and touches no
    // MMDevice object: the whole point is that it returns before the audio
    // service's dispatch lock can matter. The handler on the other side is a
    // PostMessage.
    void requestRearm() {
        if (facade && facade->onDeviceChanged) facade->onDeviceChanged();
    }

    // (Re)binds the volume interface to the current default output device.
    // Runs on the daemon's message thread only, via rearm() -- never from a
    // notification callback any more. Still guarded, because it races
    // OnNotify-driven publish()
    // on yet another thread — so every swap of `volume` happens under
    // publishMutex, while register/unregister/release happen OUTSIDE it
    // (unregister can block on an in-flight OnNotify that is itself waiting
    // for publishMutex).
    bool armEndpoint() {
        std::lock_guard<std::mutex> arm(armMutex);
        ComPtr<IAudioEndpointVolume> old;
        {
            std::lock_guard<std::mutex> lock(publishMutex);
            old = std::move(volume);
        }
        if (old && volumeCallback) old->UnregisterControlChangeNotify(volumeCallback.Get());
        old.Reset();

        ComPtr<IMMDevice> device;
        if (FAILED(enumerator->GetDefaultAudioEndpoint(eRender, eMultimedia, &device)))
            return false;
        ComPtr<IAudioEndpointVolume> fresh;
        if (FAILED(device->Activate(__uuidof(IAudioEndpointVolume), CLSCTX_INPROC_SERVER,
                                    nullptr, reinterpret_cast<void**>(fresh.GetAddressOf()))))
            return false;
        fresh->RegisterControlChangeNotify(volumeCallback.Get());
        {
            std::lock_guard<std::mutex> lock(publishMutex);
            volume = fresh;
        }
        return true;
    }
};

// The notification already carries the new state, so read it from `data`
// instead of calling back into the endpoint for it. Re-querying here ran a COM
// call on a WASAPI thread, inside a callback the service dispatches under its
// own lock -- the same hazard that deadlocked OnDefaultDeviceChanged, and
// pointless besides, since fMasterVolume and bMuted are right here.
HRESULT STDMETHODCALLTYPE VolumeCallback::OnNotify(PAUDIO_VOLUME_NOTIFICATION_DATA data) {
    if (!owner_ || !data) return S_OK;
    // Same muted -> 0 convention as percentFrom().
    const int percent =
        data->bMuted ? 0 : static_cast<int>(std::lround(data->fMasterVolume * 100.0f));
    owner_->publishValue(percent, false);
    return S_OK;
}

// Hand off and return. This used to call armEndpoint() and publish() inline,
// which deadlocked the bar: the audio service dispatches this notification
// with an internal lock held, and IMMNotificationClient is documented not to
// block, not to wait on a synchronization object, not to (un)register a
// notification, and not to release the last reference on an MMDevice object
// from inside a callback. armEndpoint() did all four -- it took armMutex and
// publishMutex, called UnregisterControlChangeNotify, dropped the old endpoint
// and then re-entered GetDefaultAudioEndpoint/Activate.
//
// Captured live (AppHangB1, a full dump of the hung process): the message
// thread sat in MMDevAPI/AudioSes waiting, while a WASAPI notification thread
// was inside this callback, back down in AudioSes, blocked on a KERNELBASE
// wait. Connecting or waking a Bluetooth audio device moves the default
// endpoint, so opening the bluetooth widget was a reliable way to fire it.
//
// The re-arm now happens on the daemon's message thread, which owns no audio
// lock when it runs.
HRESULT STDMETHODCALLTYPE DeviceCallback::OnDefaultDeviceChanged(EDataFlow flow, ERole role,
                                                                 LPCWSTR) {
    if (owner_ && flow == eRender && role == eMultimedia) owner_->requestRearm();
    return S_OK;
}

AudioProvider::AudioProvider() : impl_(std::make_unique<AudioProviderImpl>()) {
    impl_->facade = this;
}

AudioProvider::~AudioProvider() { stop(); }

bool AudioProvider::start() {
    if (impl_->running) return true;
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&impl_->enumerator))))
        return false;
    impl_->volumeCallback.Attach(new VolumeCallback(impl_.get()));
    impl_->deviceCallback.Attach(new DeviceCallback(impl_.get()));
    impl_->enumerator->RegisterEndpointNotificationCallback(impl_->deviceCallback.Get());
    if (!impl_->armEndpoint()) {
        // No default render endpoint (headless session, disabled audio).
        // The device-notification registration is already live and holds a
        // reference to a callback whose owner is about to be freed — it MUST
        // be unregistered here, or the next device arrival calls into a
        // dangling AudioProviderImpl.
        stop();
        return false;
    }
    impl_->running = true;
    impl_->publish(true); // seed the first value
    return true;
}

void AudioProvider::stop() {
    // Guarded on the enumerator, not `running`: a failed start() leaves a
    // partially armed provider (registration live, running still false) that
    // must be torn down the same way.
    if (!impl_ || !impl_->enumerator) return;
    // Order matters: unhook the device notification FIRST (no locks held —
    // it synchronizes with in-flight OnDefaultDeviceChanged, which may be
    // waiting on armMutex), so no NEW arm can start; then wait out any arm
    // already in flight before harvesting the endpoint it may have created.
    if (impl_->deviceCallback)
        impl_->enumerator->UnregisterEndpointNotificationCallback(impl_->deviceCallback.Get());
    ComPtr<IAudioEndpointVolume> old;
    {
        std::lock_guard<std::mutex> arm(impl_->armMutex);
        std::lock_guard<std::mutex> lock(impl_->publishMutex);
        old = std::move(impl_->volume);
    }
    if (old && impl_->volumeCallback)
        old->UnregisterControlChangeNotify(impl_->volumeCallback.Get());
    old.Reset();
    impl_->enumerator.Reset();
    impl_->running = false;
}

bool AudioProvider::rearm() {
    if (!impl_->running) return false;
    // Both halves were what OnDefaultDeviceChanged used to run inline; they
    // are safe here because this thread holds no audio-service lock.
    const bool ok = impl_->armEndpoint();
    impl_->publish(true); // the new device's level is news either way
    return ok;
}

bool AudioProvider::refresh() {
    if (!impl_->running && !start()) return false;
    impl_->publish(true);
    return true;
}

bool AudioProvider::setVolume(int percent) {
    if (!impl_->running && !start()) return false;
    // Snapshot under publishMutex, call COM outside it (file rule above):
    // the AddRef'd endpoint stays valid across a concurrent device swap,
    // and IAudioEndpointVolume is free-threaded.
    ComPtr<IAudioEndpointVolume> endpoint;
    {
        std::lock_guard<std::mutex> lock(impl_->publishMutex);
        endpoint = impl_->volume;
    }
    if (!endpoint) return false;
    const int clamped = percent < 0 ? 0 : (percent > 100 ? 100 : percent);
    if (clamped == 0) {
        // Keep the scalar: unmuting later restores the previous level, the
        // same round trip the muted->0 read convention implies.
        return SUCCEEDED(endpoint->SetMute(TRUE, nullptr));
    }
    // Scalar before unmute so a muted endpoint cannot blip its old level.
    if (FAILED(endpoint->SetMasterVolumeLevelScalar(static_cast<float>(clamped) / 100.0f,
                                                    nullptr)))
        return false;
    endpoint->SetMute(FALSE, nullptr);
    return true;
}

} // namespace ybar::providers
