import AppKit
import Metal
import MetalKit
// ScreenCaptureKit's Sendable annotations landed after the macOS 15 SDK.
@preconcurrency import ScreenCaptureKit

/// Desktop strip behind each bar, about 8 times a second. The liquid-lens
/// shader refracts the latest image; a denied Screen Recording grant simply
/// never calls `onTexture`, and the pills stay on system glass.
@MainActor
final class LensBackdrop {
    var onTexture: ((Int, MTLTexture) -> Void)?
    var targets: () -> [(arrangement: Int, windowID: CGWindowID, screen: NSScreen, barFrame: CGRect)] = { [] }

    private let loader: MTKTextureLoader
    private var timer: Timer?
    private var inFlight = false
    /// One system dialog per process. A denial leaves the timer stopped.
    private var didRequestAccess = false
    private var loggedFailure = false

    init(device: MTLDevice) {
        loader = MTKTextureLoader(device: device)
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard !inFlight else { return }
        // SCShareableContent itself raises the Screen Recording dialog. Calling
        // it on the 8 Hz timer restacks that dialog until the user answers.
        if !CGPreflightScreenCaptureAccess() {
            stop()
            guard !didRequestAccess else { return }
            didRequestAccess = true
            if CGRequestScreenCaptureAccess() {
                start()
            }
            return
        }
        let shots = targets()
        guard !shots.isEmpty else { return }
        inFlight = true
        Task { @MainActor [weak self] in
            defer { self?.inFlight = false }
            guard let self else { return }
            let content: SCShareableContent
            do {
                content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true)
            } catch {
                self.logFailure("shareable content: \(error)")
                return
            }
            for shot in shots {
                let displayID = (shot.screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
                guard let display = content.displays.first(where: { $0.displayID == displayID })
                else { continue }
                let exclude = content.windows.filter { $0.windowID == shot.windowID }
                let filter = SCContentFilter(display: display, excludingWindows: exclude)
                let scale = shot.screen.backingScaleFactor
                let displayFrame = shot.screen.frame
                // From the bar downward through the windows, not just the
                // thin strip the bar covers. Refraction needs that content
                // or the pill is a flat tint with nothing to bend.
                var source = CGRect(
                    x: shot.barFrame.minX - displayFrame.minX,
                    y: displayFrame.maxY - shot.barFrame.maxY,
                    width: shot.barFrame.width,
                    height: min(720, displayFrame.height - (displayFrame.maxY - shot.barFrame.maxY)))
                source.size.height = max(shot.barFrame.height, source.size.height)
                source.size.width = min(source.width, max(1, displayFrame.width - source.minX))
                guard source.width > 1, source.height > 1 else { continue }
                let configuration = SCStreamConfiguration()
                configuration.sourceRect = source
                configuration.width = max(1, Int(source.width * scale))
                configuration.height = max(1, Int(source.height * scale))
                configuration.showsCursor = false
                let image: CGImage
                do {
                    image = try await SCScreenshotManager.captureImage(
                        contentFilter: filter, configuration: configuration)
                } catch {
                    self.logFailure("capture: \(error)")
                    continue
                }
                guard let texture = try? await self.loader.newTexture(cgImage: image, options: [
                    .SRGB: true,
                    .origin: MTKTextureLoader.Origin.topLeft,
                    .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                ]) else { continue }
                self.onTexture?(shot.arrangement, texture)
            }
        }
    }

    private func logFailure(_ message: String) {
        guard !loggedFailure else { return }
        loggedFailure = true
        FileHandle.standardError.write(Data("[ybar] liquid lens \(message)\n".utf8))
    }
}
