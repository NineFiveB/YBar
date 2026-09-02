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

    void publish(bool forced) {
        std::lock_guard<std::mutex> lock(publishMutex);
        const int percent = percentFrom(volume.Get());
        if (!forced && percent == lastPercent) return; // deduped (spec 10)
        lastPercent = percent;
        if (facade && facade->onVolume) facade->onVolume(percent);
    }

    // (Re)binds the volume interface to the current default output device.
    // Runs on the MMDevice notification thread (OnDefaultDeviceChanged) as
    // well as the daemon thread, concurrently with OnNotify-driven publish()
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

HRESULT STDMETHODCALLTYPE VolumeCallback::OnNotify(PAUDIO_VOLUME_NOTIFICATION_DATA) {
    if (owner_) owner_->publish(false);
    return S_OK;
}

HRESULT STDMETHODCALLTYPE DeviceCallback::OnDefaultDeviceChanged(EDataFlow flow, ERole role,
                                                                 LPCWSTR) {
    if (owner_ && flow == eRender && role == eMultimedia) {
        owner_->armEndpoint();
        owner_->publish(true); // the new device's level is news either way
    }
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
