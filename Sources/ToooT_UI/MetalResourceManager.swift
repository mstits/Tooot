import Metal
import MetalKit

/// Equation-Grade Metal Resource Manager.
/// Pre-warms all PSO (Pipeline State Objects) once to prevent frame-time stalls.
@globalActor public actor MetalResourceManager {
    public static let shared = MetalResourceManager()
    
    private let device: MTLDevice
    private var pipelines: [String: Any] = [:]
    
    private init() {
        self.device = MTLCreateSystemDefaultDevice()!
    }
    
    public func getDevice() -> MTLDevice { return device }
    
    /// Pre-warms the spatial mesh pipeline.
    public func prepareSpatialPipeline(pixelFormat: MTLPixelFormat) async throws -> MTLRenderPipelineState {
        let key = "spatial-\(pixelFormat.rawValue)"
        if let pso = pipelines[key] as? MTLRenderPipelineState { return pso }
        
        let library = try await device.makeLibrary(source: Shaders.source, options: nil)
        
        if #available(macOS 13.0, *) {
            let meshFunc = library.makeFunction(name: "spatial_mesh_shader")!
            let fragFunc = library.makeFunction(name: "spatial_fragment")!
            
            let desc = MTLMeshRenderPipelineDescriptor()
            desc.meshFunction = meshFunc
            desc.fragmentFunction = fragFunc
            desc.colorAttachments[0].pixelFormat = pixelFormat
            
            let (pso, _) = try await device.makeRenderPipelineState(descriptor: desc, options: [])
            pipelines[key] = pso
            return pso
        } else {
            throw NSError(domain: "MetalResourceManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Mesh shaders require macOS 13+"])
        }
    }
    
    public func prepareSpectrogramPipeline(pixelFormat: MTLPixelFormat) async throws -> MTLRenderPipelineState {
        let key = "spectro-\(pixelFormat.rawValue)"
        if let pso = pipelines[key] as? MTLRenderPipelineState { return pso }
        
        let library = try await device.makeLibrary(source: Shaders.source, options: nil)
        let vertFunc = library.makeFunction(name: "spectrogram_vertex")!
        let fragFunc = library.makeFunction(name: "spectrogram_fragment")!
        
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertFunc
        desc.fragmentFunction = fragFunc
        desc.colorAttachments[0].pixelFormat = pixelFormat
        
        let pso = try await device.makeRenderPipelineState(descriptor: desc)
        pipelines[key] = pso
        return pso
    }
    
    public func preparePatternPipeline(pixelFormat: MTLPixelFormat) async throws -> MTLRenderPipelineState {
        let key = "pattern-\(pixelFormat.rawValue)"
        if let pso = pipelines[key] as? MTLRenderPipelineState { return pso }
        
        let library = try await device.makeLibrary(source: Shaders.source, options: nil)
        let vertFunc = library.makeFunction(name: "grid_vertex")!
        let fragFunc = library.makeFunction(name: "grid_fragment")!
        
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction   = vertFunc
        descriptor.fragmentFunction = fragFunc
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor      = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        
        let pso = try await device.makeRenderPipelineState(descriptor: descriptor)
        pipelines[key] = pso
        return pso
    }
}
