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

    void publish(bool forced) {
        std::lock_guard<std::mutex> lock(publishMutex);
        const int percent = percentFrom(volume.Get());
        if (!forced && percent == lastPercent) return; // deduped (spec 10)
        lastPercent = percent;
        if (facade && facade->onVolume) facade->onVolume(percent);
    }

    // (Re)binds the volume interface to the current default output device.
    bool armEndpoint() {
        if (volume && volumeCallback) volume->UnregisterControlChangeNotify(volumeCallback.Get());
        volume.Reset();
        ComPtr<IMMDevice> device;
        if (FAILED(enumerator->GetDefaultAudioEndpoint(eRender, eMultimedia, &device)))
            return false;
        if (FAILED(device->Activate(__uuidof(IAudioEndpointVolume), CLSCTX_INPROC_SERVER,
                                    nullptr, reinterpret_cast<void**>(volume.GetAddressOf()))))
            return false;
        volume->RegisterControlChangeNotify(volumeCallback.Get());
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
    if (!impl_->armEndpoint()) return false;
    impl_->running = true;
    impl_->publish(true); // seed the first value
    return true;
}

void AudioProvider::stop() {
    if (!impl_ || !impl_->running) return;
    if (impl_->volume && impl_->volumeCallback)
        impl_->volume->UnregisterControlChangeNotify(impl_->volumeCallback.Get());
    if (impl_->enumerator && impl_->deviceCallback)
        impl_->enumerator->UnregisterEndpointNotificationCallback(impl_->deviceCallback.Get());
    impl_->volume.Reset();
    impl_->enumerator.Reset();
    impl_->running = false;
}

bool AudioProvider::refresh() {
    if (!impl_->running && !start()) return false;
    impl_->publish(true);
    return true;
}

} // namespace ybar::providers
