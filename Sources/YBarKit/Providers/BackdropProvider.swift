import AppKit
import CoreVideo
import Metal
// @preconcurrency for the same reason AliasProvider needs it: ScreenCaptureKit
// gained its Sendable annotations after the macOS 15 SDK, and README still
// promises macOS 14.
@preconcurrency import ScreenCaptureKit

/// Supplies the texture the glass rim refracts (`--bar refraction`).
///
/// The renderer draws OVER the system material and never reads it, so a
/// refraction needs a picture of what is behind the bar from somewhere else.
/// There are exactly two places to get one, and this class is the choice
/// between them:
///
/// - `.screen` captures the strip with ScreenCaptureKit. Correct over any
///   window, and the only mode that can raise the Screen Recording prompt.
/// - `.wallpaper` reads the desktop picture. No permission, no capture, a
///   texture loaded once — but a lie the moment a window reaches the top of
///   the screen, so it withdraws while one is up there.
///
/// Both cost nothing at rest. The capture skips frames ScreenCaptureKit marks
/// idle (measured on a 1512x44 strip: 73 idle against 20 real over six quiet
/// seconds), and the wallpaper texture never changes at all. That matters
/// because "nothing changes, nothing draws" is a property of the whole bar,
/// not a detail of this file.
@MainActor
public final class BackdropProvider {
    /// A new backdrop landed — repaint.
    public var onFrame: (() -> Void)?

    /// The current backdrop, or nil when there is none to refract.
    public private(set) var texture: MTLTexture?
    /// Screen rect the texture was captured for, in points. The caller
    /// compares this against the surface it is about to draw: a bar that has
    /// moved or resized must not refract the frame captured for its old
    /// geometry.
    public private(set) var capturedRect: CGRect = .zero

    private let device: MTLDevice
    private var textureCache: CVMetalTextureCache?
    /// CVMetalTextureGetTexture's result lives only as long as its
    /// CVMetalTexture, so the wrapper is held for exactly as long as the
    /// texture it vends.
    private var liveCVTexture: CVMetalTexture?

    private var mode: RefractionMode = .off
    /// What `.auto` settled on, so the caller can report it back.
    public private(set) var effectiveMode: RefractionMode = .off

    private var stream: SCStream?
    private var streamOutput: StreamOutput?
    private var targetRect: CGRect = .zero
    private var targetScale: CGFloat = 2
    private var desktopWatch: Timer?
    private var wallpaperImage: CGImage?
    private var wallpaperScreenFrame: CGRect = .zero

    /// A rim band a few pixels wide carries no high frequencies, so the
    /// capture is taken at a quarter of the strip's size. 1512x44 becomes
    /// 378x11 — small enough that the upload is noise.
    private static let downscale = 4

    public init(device: MTLDevice) {
        self.device = device
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    // MARK: - Mode

    /// Point the provider at a surface. Safe to call on every geometry change;
    /// it restarts the source only when something it depends on actually moved.
    public func apply(mode: RefractionMode, rect: CGRect, scale: CGFloat) {
        let geometryChanged = rect != targetRect || scale != targetScale
        targetRect = rect
        targetScale = scale
        guard mode != self.mode || geometryChanged else { return }
        self.mode = mode
        restart()
    }

    public func stop() {
        mode = .off
        restart()
    }

    private func restart() {
        stopScreenCapture()
        stopDesktopWatch()
        clearTexture()

        switch resolve(mode) {
        case .off:
            effectiveMode = .off
        case .screen:
            effectiveMode = .screen
            startScreenCapture()
        case .wallpaper:
            effectiveMode = .wallpaper
            startWallpaper()
        case .auto:
            effectiveMode = .off   // resolve() never returns auto
        }
        onFrame?()
    }

    /// `.auto` takes what is already available and asks for nothing:
    /// CGPreflightScreenCaptureAccess reports the permission WITHOUT
    /// prompting, which is the whole reason the mode can exist.
    private func resolve(_ mode: RefractionMode) -> RefractionMode {
        switch mode {
        case .off, .screen, .wallpaper: return mode
        case .auto:
            if CGPreflightScreenCaptureAccess() { return .screen }
            return .wallpaper
        }
    }

    private func clearTexture() {
        texture = nil
        liveCVTexture = nil
        capturedRect = .zero
    }

    // MARK: - ScreenCaptureKit

    private func startScreenCapture() {
        guard !targetRect.isEmpty else { return }
        // `screen` is the one mode allowed to ask, and this is where it asks.
        // A LaunchAgent has no foreground to show a sheet in, so the call
        // registers YBar in System Settings > Screen Recording and notifies;
        // the grant takes effect on the next launch. Until then the capture
        // starts and delivers nothing, which is why the failure path below
        // falls back instead of leaving the bar with a dead setting.
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        let rect = targetRect
        let scale = targetScale
        Task { [weak self] in
            let content = try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            guard let self else { return }
            guard let content else { return self.fallBackToWallpaper() }
            guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) })
                ?? NSScreen.main,
                let number = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                let display = content.displays.first(where: { $0.displayID == number.uint32Value })
            else { return self.fallBackToWallpaper() }

            // Our own output can never be part of the backdrop, or the rim
            // refracts the rim it drew last frame.
            let ours = content.windows.filter { window in
                guard let app = window.owningApplication else { return false }
                return app.processID == ProcessInfo.processInfo.processIdentifier
            }

            let configuration = SCStreamConfiguration()
            // Display-local, top-left origin: AppKit's global frame is
            // bottom-left, so the strip's y is measured down from the top.
            configuration.sourceRect = CGRect(
                x: rect.minX - screen.frame.minX,
                y: screen.frame.maxY - rect.maxY,
                width: rect.width,
                height: rect.height)
            configuration.width =
                max(1, Int(rect.width * scale) / BackdropProvider.downscale)
            configuration.height =
                max(1, Int(rect.height * scale) / BackdropProvider.downscale)
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 15)
            configuration.queueDepth = 3
            configuration.showsCursor = false
            configuration.pixelFormat = kCVPixelFormatType_32BGRA

            let filter = SCContentFilter(display: display, excludingWindows: ours)
            let output = StreamOutput { [weak self] buffer in
                Task { @MainActor in self?.adopt(pixelBuffer: buffer, rect: rect) }
            }
            let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
            do {
                try stream.addStreamOutput(
                    output, type: .screen,
                    sampleHandlerQueue: DispatchQueue(label: "com.ybar.backdrop"))
                try await stream.startCapture()
            } catch {
                // Denied, or the display went away. The bar still draws either
                // way, but silently doing nothing would leave `refraction=screen`
                // looking broken, so drop to the source that needs no
                // permission and say so through `refraction_source`.
                return self.fallBackToWallpaper()
            }
            self.stream = stream
            self.streamOutput = output
        }
    }

    /// Screen capture was asked for and could not be had. The wallpaper needs
    /// nothing, so take it rather than leaving the mode inert — `--query bar`
    /// reports which source is really running.
    private func fallBackToWallpaper() {
        guard mode == .screen || mode == .auto, effectiveMode != .wallpaper else { return }
        effectiveMode = .wallpaper
        startWallpaper()
    }

    private func stopScreenCapture() {
        guard let stream else { return }
        self.stream = nil
        streamOutput = nil
        Task { try? await stream.stopCapture() }
    }

    private func adopt(pixelBuffer: CVPixelBuffer, rect: CGRect) {
        guard let cache = textureCache else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var wrapper: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .bgra8Unorm_srgb, width, height, 0, &wrapper)
        guard status == kCVReturnSuccess,
              let wrapper, let made = CVMetalTextureGetTexture(wrapper) else { return }
        liveCVTexture = wrapper
        texture = made
        capturedRect = rect
        onFrame?()
    }

    // MARK: - Wallpaper

    private func startWallpaper() {
        loadWallpaper()
        refreshWallpaperAvailability()
        // A window sliding across the strip is not an event anything reports,
        // so this is the one poll in the file — and it only runs in the one
        // mode that needs it, reading window BOUNDS, which needs no permission.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWallpaperAvailability() }
        }
        RunLoop.main.add(timer, forMode: .common)
        desktopWatch = timer
    }

    private func stopDesktopWatch() {
        desktopWatch?.invalidate()
        desktopWatch = nil
        wallpaperImage = nil
    }

    private func loadWallpaper() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(targetRect) })
            ?? NSScreen.main,
            let url = NSWorkspace.shared.desktopImageURL(for: screen),
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return }
        wallpaperImage = image
        wallpaperScreenFrame = screen.frame
    }

    /// True while the desktop is what sits under the strip. Window bounds and
    /// layers come back without Screen Recording — only titles and pixels
    /// need it, and this asks for neither.
    private func desktopIsBehind() -> Bool {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let strip = CGRect(
            x: targetRect.minX - wallpaperScreenFrame.minX,
            y: wallpaperScreenFrame.maxY - targetRect.maxY,
            width: targetRect.width, height: targetRect.height)
        let ourPID = ProcessInfo.processInfo.processIdentifier
        for window in list {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer <= 0,
                  let pid = window[kCGWindowOwnerPID as String] as? Int32, pid != ourPID,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat]
            else { continue }
            let frame = CGRect(
                x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            if frame.intersects(strip) { return false }
        }
        return true
    }

    private func refreshWallpaperAvailability() {
        let available = desktopIsBehind()
        if available {
            guard texture == nil else { return }
            makeWallpaperTexture()
        } else if texture != nil {
            clearTexture()
            onFrame?()
        }
    }

    /// Crops the desktop picture to the strip's share of the screen, assuming
    /// the fill scaling macOS uses by default. An exotic tiling option would
    /// put the crop in the wrong place — which costs a wrong local contrast at
    /// the rim, not a wrong colour, because the shader adds a difference.
    private func makeWallpaperTexture() {
        guard let image = wallpaperImage, !wallpaperScreenFrame.isEmpty else { return }
        let screen = wallpaperScreenFrame
        let imageW = CGFloat(image.width), imageH = CGFloat(image.height)
        let fill = max(screen.width / imageW, screen.height / imageH)
        let shownW = imageW * fill, shownH = imageH * fill
        let originX = (shownW - screen.width) / 2
        let originY = (shownH - screen.height) / 2
        let stripTop = screen.maxY - targetRect.maxY
        let crop = CGRect(
            x: (originX + targetRect.minX - screen.minX) / fill,
            y: (originY + stripTop) / fill,
            width: targetRect.width / fill,
            height: targetRect.height / fill)
        guard let cropped = image.cropping(to: crop) else { return }

        let width = max(1, Int(targetRect.width * targetScale) / BackdropProvider.downscale)
        let height = max(1, Int(targetRect.height * targetScale) / BackdropProvider.downscale)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let made = device.makeTexture(descriptor: descriptor) else { return }

        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let context = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        made.replace(
            region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
            withBytes: bytes, bytesPerRow: bytesPerRow)

        liveCVTexture = nil
        texture = made
        capturedRect = targetRect
        onFrame?()
    }
}

/// SCStream hands frames to a delegate on a background queue. Frames it marks
/// idle are dropped here, before any texture work: a still screen must cost
/// nothing, which is the entire argument for capturing continuously at all.
private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let deliver: (CVPixelBuffer) -> Void

    init(deliver: @escaping (CVPixelBuffer) -> Void) {
        self.deliver = deliver
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let status = attachments.first?[.status] as? Int,
            status == SCFrameStatus.complete.rawValue,
            let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        deliver(pixelBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {}
}
