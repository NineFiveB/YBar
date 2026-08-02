import AppKit
import CoreText
import Metal
import simd

/// Glyph atlas: two texture pages per display scale.
/// - mask page (`r8Unorm`): monochrome glyph coverage + template SF Symbols, tinted in-shader
/// - color page (`bgra8Unorm`, premultiplied): emoji and other color glyphs
/// Packing is a simple shelf packer; pages are fixed-size in v1 (a full page logs
/// a warning and skips the glyph — growth/eviction is a planned refinement).
@MainActor
public final class GlyphAtlas {
    public struct Entry {
        public let uvOrigin: SIMD2<Float>
        public let uvSize: SIMD2<Float>
        /// Quad size in device pixels.
        public let sizePx: SIMD2<Float>
        /// Offset from the pen point (baseline origin) to the quad's top-left, y-down device px.
        public let bearingPx: SIMD2<Float>
        public let isColor: Bool
    }

    private struct GlyphKey: Hashable {
        let fontName: String
        let fontSize: CGFloat
        let glyph: CGGlyph
    }

    public let scale: CGFloat
    public private(set) var maskTexture: MTLTexture
    public private(set) var colorTexture: MTLTexture

    private var glyphEntries: [GlyphKey: Entry?] = [:]
    private var symbolEntries: [String: Entry?] = [:]
    private var maskPacker: ShelfPacker
    private var colorPacker: ShelfPacker

    private static let maskPageSize = 2048
    private static let colorPageSize = 1024
    private static let padding = 1

    public init?(device: MTLDevice, scale: CGFloat) {
        self.scale = scale

        let maskDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: GlyphAtlas.maskPageSize, height: GlyphAtlas.maskPageSize, mipmapped: false)
        maskDescriptor.storageMode = .shared
        // _srgb so sampling decodes emoji texels to linear, matching the
        // linear-light render target.
        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: GlyphAtlas.colorPageSize, height: GlyphAtlas.colorPageSize, mipmapped: false)
        colorDescriptor.storageMode = .shared

        guard let mask = device.makeTexture(descriptor: maskDescriptor),
              let color = device.makeTexture(descriptor: colorDescriptor)
        else { return nil }
        maskTexture = mask
        colorTexture = color
        maskPacker = ShelfPacker(width: GlyphAtlas.maskPageSize, height: GlyphAtlas.maskPageSize)
        colorPacker = ShelfPacker(width: GlyphAtlas.colorPageSize, height: GlyphAtlas.colorPageSize)
    }

    // MARK: - Glyphs

    public func entry(glyph: CGGlyph, font: CTFont) -> Entry? {
        let key = GlyphKey(
            fontName: (CTFontCopyPostScriptName(font) as String),
            fontSize: CTFontGetSize(font),
            glyph: glyph)
        if let cached = glyphEntries[key] { return cached }
        let entry = rasterizeGlyph(glyph: glyph, font: font)
        glyphEntries[key] = entry
        return entry
    }

    private func rasterizeGlyph(glyph: CGGlyph, font: CTFont) -> Entry? {
        var mutableGlyph = glyph
        var bounds = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .default, &mutableGlyph, &bounds, 1)
        guard !bounds.isEmpty else { return nil }

        let pad = CGFloat(GlyphAtlas.padding)
        let minX = floor(bounds.minX * scale) - pad
        let minY = floor(bounds.minY * scale) - pad
        let maxX = ceil(bounds.maxX * scale) + pad
        let maxY = ceil(bounds.maxY * scale) + pad
        let width = Int(maxX - minX)
        let height = Int(maxY - minY)
        guard width > 0, height > 0 else { return nil }

        let isColor = CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs)
        let position = CGPoint(x: -minX / scale, y: -minY / scale)

        if isColor {
            guard let context = GlyphAtlas.makeColorContext(width: width, height: height) else { return nil }
            context.scaleBy(x: scale, y: scale)
            var origin = position
            withUnsafePointer(to: mutableGlyph) { glyphPointer in
                CTFontDrawGlyphs(font, glyphPointer, &origin, 1, context)
            }
            return upload(context: context, width: width, height: height,
                          bearing: SIMD2(Float(minX), Float(-maxY)), isColor: true)
        } else {
            guard let context = GlyphAtlas.makeMaskContext(width: width, height: height) else { return nil }
            context.scaleBy(x: scale, y: scale)
            context.setAllowsFontSmoothing(false)
            var origin = position
            withUnsafePointer(to: mutableGlyph) { glyphPointer in
                CTFontDrawGlyphs(font, glyphPointer, &origin, 1, context)
            }
            return upload(context: context, width: width, height: height,
                          bearing: SIMD2(Float(minX), Float(-maxY)), isColor: false)
        }
    }

    // MARK: - SF Symbols

    /// Rasterize a (template) SF Symbol into the mask page so it tints like text.
    public func entry(symbolImage: NSImage, cacheKey: String) -> Entry? {
        if let cached = symbolEntries[cacheKey] { return cached }
        let entry = rasterizeSymbol(image: symbolImage)
        symbolEntries[cacheKey] = entry
        return entry
    }

    private func rasterizeSymbol(image: NSImage) -> Entry? {
        let sizePoints = image.size
        let width = Int(ceil(sizePoints.width * scale))
        let height = Int(ceil(sizePoints.height * scale))
        guard width > 0, height > 0 else { return nil }

        var proposedRect = CGRect(origin: .zero, size: sizePoints)
        let hints: [NSImageRep.HintKey: Any] = [
            .ctm: NSAffineTransform(transform: AffineTransform(scale: scale))
        ]
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: hints),
              let context = GlyphAtlas.makeMaskContext(width: width, height: height)
        else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Symbols are centered vertically by the scene builder; bearing carries width only.
        return upload(context: context, width: width, height: height,
                      bearing: SIMD2(0, 0), isColor: false)
    }

    // MARK: - Live (replaceable) images — alias captures

    private var liveRects: [String: (x: Int, y: Int, w: Int, h: Int)] = [:]

    /// Upload a frequently-changing image (alias capture). Re-uses the same
    /// atlas rect while the pixel size is stable so live captures don't leak
    /// shelf space; a size change allocates a fresh rect.
    public func liveEntry(cgImage: CGImage, cacheKey: String) -> Entry? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0,
              let context = GlyphAtlas.makeColorContext(width: width, height: height)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }

        if let rect = liveRects[cacheKey], rect.w == width, rect.h == height {
            let region = MTLRegion(
                origin: MTLOrigin(x: rect.x, y: rect.y, z: 0),
                size: MTLSize(width: width, height: height, depth: 1))
            colorTexture.replace(region: region, mipmapLevel: 0, withBytes: data,
                                 bytesPerRow: context.bytesPerRow)
            let page = Float(GlyphAtlas.colorPageSize)
            return Entry(
                uvOrigin: SIMD2(Float(rect.x) / page, Float(rect.y) / page),
                uvSize: SIMD2(Float(width) / page, Float(height) / page),
                sizePx: SIMD2(Float(width), Float(height)),
                bearingPx: SIMD2(0, 0), isColor: true)
        }
        guard let origin = colorPacker.allocate(width: width, height: height) else {
            FileHandle.standardError.write(Data("[ybar] atlas full — alias capture skipped\n".utf8))
            return nil
        }
        liveRects[cacheKey] = (origin.x, origin.y, width, height)
        let region = MTLRegion(
            origin: MTLOrigin(x: origin.x, y: origin.y, z: 0),
            size: MTLSize(width: width, height: height, depth: 1))
        colorTexture.replace(region: region, mipmapLevel: 0, withBytes: data,
                             bytesPerRow: context.bytesPerRow)
        let page = Float(GlyphAtlas.colorPageSize)
        return Entry(
            uvOrigin: SIMD2(Float(origin.x) / page, Float(origin.y) / page),
            uvSize: SIMD2(Float(width) / page, Float(height) / page),
            sizePx: SIMD2(Float(width), Float(height)),
            bearingPx: SIMD2(0, 0), isColor: true)
    }

    // MARK: - Images

    /// Rasterize an arbitrary image (app icons) into the color page.
    /// `sizePoints` is the on-bar display size; the bitmap is rendered at
    /// the atlas scale for crispness. Cached by key like symbols.
    public func entry(colorImage image: NSImage, cacheKey: String, sizePoints: CGSize) -> Entry? {
        if let cached = symbolEntries[cacheKey] { return cached }
        let entry = rasterizeColorImage(image: image, sizePoints: sizePoints)
        symbolEntries[cacheKey] = entry
        return entry
    }

    private func rasterizeColorImage(image: NSImage, sizePoints: CGSize) -> Entry? {
        let width = Int(ceil(sizePoints.width * scale))
        let height = Int(ceil(sizePoints.height * scale))
        guard width > 0, height > 0 else { return nil }

        var proposedRect = CGRect(origin: .zero, size: sizePoints)
        let hints: [NSImageRep.HintKey: Any] = [
            .ctm: NSAffineTransform(transform: AffineTransform(scale: scale))
        ]
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: hints),
              let context = GlyphAtlas.makeColorContext(width: width, height: height)
        else { return nil }
        context.interpolationQuality = .high
        // Aspect-fit: non-square sources (SF symbols are often wide) letterbox
        // inside the square cell instead of stretching.
        let sourceSize = CGSize(width: cgImage.width, height: cgImage.height)
        let fit = min(CGFloat(width) / sourceSize.width, CGFloat(height) / sourceSize.height)
        let drawSize = CGSize(width: sourceSize.width * fit, height: sourceSize.height * fit)
        context.draw(cgImage, in: CGRect(
            x: (CGFloat(width) - drawSize.width) / 2,
            y: (CGFloat(height) - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height))
        return upload(context: context, width: width, height: height,
                      bearing: SIMD2(0, 0), isColor: true)
    }

    // MARK: - Upload

    private func upload(context: CGContext, width: Int, height: Int,
                        bearing: SIMD2<Float>, isColor: Bool) -> Entry? {
        let packer = isColor ? colorPacker : maskPacker
        guard let origin = packer.allocate(width: width, height: height) else {
            FileHandle.standardError.write(Data("[ybar] glyph atlas page full — glyph skipped\n".utf8))
            return nil
        }
        guard let data = context.data else { return nil }

        let texture = isColor ? colorTexture : maskTexture
        let region = MTLRegion(
            origin: MTLOrigin(x: origin.x, y: origin.y, z: 0),
            size: MTLSize(width: width, height: height, depth: 1))
        texture.replace(region: region, mipmapLevel: 0, withBytes: data,
                        bytesPerRow: context.bytesPerRow)

        let pageSize = Float(isColor ? GlyphAtlas.colorPageSize : GlyphAtlas.maskPageSize)
        return Entry(
            uvOrigin: SIMD2(Float(origin.x) / pageSize, Float(origin.y) / pageSize),
            uvSize: SIMD2(Float(width) / pageSize, Float(height) / pageSize),
            sizePx: SIMD2(Float(width), Float(height)),
            bearingPx: bearing,
            isColor: isColor)
    }

    private static func makeMaskContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
    }

    private static func makeColorContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)
    }
}

/// Minimal shelf bin packer: rows of decreasing availability, no reclamation.
final class ShelfPacker {
    private let width: Int
    private let height: Int
    private var shelves: [(y: Int, height: Int, cursorX: Int)] = []
    private var nextShelfY = 0

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    func allocate(width itemWidth: Int, height itemHeight: Int) -> (x: Int, y: Int)? {
        guard itemWidth <= width else { return nil }
        for index in shelves.indices {
            let shelf = shelves[index]
            if itemHeight <= shelf.height, shelf.cursorX + itemWidth <= width {
                shelves[index].cursorX += itemWidth
                return (shelf.cursorX, shelf.y)
            }
        }
        // Open a new shelf, slightly taller than requested to improve reuse.
        let shelfHeight = itemHeight + (itemHeight / 8)
        guard nextShelfY + shelfHeight <= height else { return nil }
        let shelf = (y: nextShelfY, height: shelfHeight, cursorX: itemWidth)
        shelves.append(shelf)
        nextShelfY += shelfHeight
        return (0, shelf.y)
    }
}
