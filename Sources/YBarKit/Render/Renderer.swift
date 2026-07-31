import Metal
import QuartzCore
import simd

/// Encodes a DisplayList into one Metal frame: two instanced draws
/// (SDF quads, then atlas glyphs) over a transparent clear.
/// Triple-buffered shared-storage instance buffers behind a semaphore.
@MainActor
public final class Renderer {
    public enum RendererError: Error {
        case noDevice
        case libraryLoadFailed
        case pipelineFailed
    }

    public let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let quadPipeline: MTLRenderPipelineState
    private let shapePipeline: MTLRenderPipelineState
    private let glyphPipeline: MTLRenderPipelineState

    private static let framesInFlight = 3
    private let frameSemaphore = DispatchSemaphore(value: Renderer.framesInFlight)
    private var quadBuffers = [MTLBuffer?](repeating: nil, count: Renderer.framesInFlight)
    private var shapeBuffers = [MTLBuffer?](repeating: nil, count: Renderer.framesInFlight)
    private var glyphBuffers = [MTLBuffer?](repeating: nil, count: Renderer.framesInFlight)
    private var frameIndex = 0

    public init(device: MTLDevice) throws {
        InstanceLayout.validate()
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw RendererError.noDevice }
        commandQueue = queue

        // Shaders compile from source at startup (once, milliseconds) so builds
        // don't require the Xcode metal toolchain.
        let library: MTLLibrary
        do {
            guard let shaderURL = Bundle.module.url(forResource: "YBar", withExtension: "metal"),
                  let source = try? String(contentsOf: shaderURL, encoding: .utf8)
            else { throw RendererError.libraryLoadFailed }
            library = try device.makeLibrary(source: source, options: nil)
        } catch {
            FileHandle.standardError.write(Data("[ybar] shader compilation failed: \(error)\n".utf8))
            throw RendererError.libraryLoadFailed
        }

        func makePipeline(vertex: String, fragment: String) throws -> MTLRenderPipelineState {
            guard let vertexFunction = library.makeFunction(name: vertex),
                  let fragmentFunction = library.makeFunction(name: fragment)
            else { throw RendererError.pipelineFailed }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = .bgra8Unorm_srgb
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }

        quadPipeline = try makePipeline(vertex: "quad_vertex", fragment: "quad_fragment")
        shapePipeline = try makePipeline(vertex: "shape_vertex", fragment: "shape_fragment")
        glyphPipeline = try makePipeline(vertex: "glyph_vertex", fragment: "glyph_fragment")
    }

    /// Render one frame into the layer. Presents even an empty list (clears the bar).
    /// Returns false when the frame could not be produced (display asleep,
    /// drawables exhausted) — the caller must reschedule or the update is lost.
    @discardableResult
    public func render(list: DisplayList, layer: CAMetalLayer, atlas: GlyphAtlas) -> Bool {
        frameSemaphore.wait()
        guard let drawable = layer.nextDrawable() else {
            frameSemaphore.signal()
            return false
        }

        let slot = frameIndex % Renderer.framesInFlight
        frameIndex += 1

        if !list.quads.isEmpty {
            quadBuffers[slot] = fill(buffer: quadBuffers[slot], with: list.quads)
        }
        if !list.triangles.isEmpty {
            shapeBuffers[slot] = fill(buffer: shapeBuffers[slot], with: list.triangles)
        }
        if !list.glyphs.isEmpty {
            glyphBuffers[slot] = fill(buffer: glyphBuffers[slot], with: list.glyphs)
        }

        let passDescriptor = MTLRenderPassDescriptor()
        let colorAttachment = passDescriptor.colorAttachments[0]!
        colorAttachment.texture = drawable.texture
        colorAttachment.loadAction = .clear
        colorAttachment.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        colorAttachment.storeAction = .store

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
        else {
            frameSemaphore.signal()
            return false
        }

        var uniforms = Uniforms(viewportSize: SIMD2(
            Float(drawable.texture.width), Float(drawable.texture.height)))

        if !list.quads.isEmpty, let buffer = quadBuffers[slot] {
            encoder.setRenderPipelineState(quadPipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: list.quads.count)
        }
        if !list.triangles.isEmpty, let buffer = shapeBuffers[slot] {
            encoder.setRenderPipelineState(shapePipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: list.triangles.count)
        }
        if !list.glyphs.isEmpty, let buffer = glyphBuffers[slot] {
            encoder.setRenderPipelineState(glyphPipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentTexture(atlas.maskTexture, index: 0)
            encoder.setFragmentTexture(atlas.colorTexture, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: list.glyphs.count)
        }

        encoder.endEncoding()
        let semaphore = frameSemaphore
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        return true
    }

    private func fill<T>(buffer: MTLBuffer?, with instances: [T]) -> MTLBuffer? {
        let needed = instances.count * MemoryLayout<T>.stride
        var target = buffer
        if target == nil || target!.length < needed {
            target = device.makeBuffer(length: max(needed, 16 * 1024), options: .storageModeShared)
        }
        guard let target else { return nil }
        instances.withUnsafeBytes { raw in
            target.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
        }
        return target
    }
}
