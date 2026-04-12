import SwiftUI
import MetalKit
import ToooT_Core

#if os(macOS)
public struct MetalSpatialView: NSViewRepresentable {
    let state: PlaybackState
    public init(state: PlaybackState) { self.state = state }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(state: state)
    }
    
    public func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 0.0)
        mtkView.colorPixelFormat = .bgra8Unorm
        return mtkView
    }
    
    public func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.prepare(mtkView: nsView)
    }
    
    public class Coordinator {
        var renderer: MetalSpatialRenderer?
        private let state: PlaybackState
        init(state: PlaybackState) {
            self.state = state
        }
        @MainActor func prepare(mtkView: MTKView) {
            guard renderer == nil else { return }
            self.renderer = MetalSpatialRenderer(state: state)
            mtkView.delegate = self.renderer
        }
    }
}

@MainActor
public final class MetalSpatialRenderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?
    private let state: PlaybackState
    private var payloadBuffer: MTLBuffer?
    private var isPrepared = false

    struct SpatialPayload {
        var position: SIMD3<Float>
        var scale: Float
    }

    public init(state: PlaybackState) {
        let device = MTLCreateSystemDefaultDevice()!
        self.commandQueue = device.makeCommandQueue()!
        self.state = state
        self.payloadBuffer = device.makeBuffer(length: MemoryLayout<SpatialPayload>.stride * kMaxChannels, options: .storageModeShared)
        super.init()
        
        Task {
            do {
                self.pipelineState = try await MetalResourceManager.shared.prepareSpatialPipeline(pixelFormat: .bgra8Unorm)
                self.isPrepared = true
            } catch {
                print("MetalSpatialRenderer failed to prepare: \(error)")
            }
        }
    }
    
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    
    public func draw(in view: MTKView) {
        guard isPrepared,
              #available(macOS 13.0, *),
              let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let pso = pipelineState,
              let payloadBuf = payloadBuffer,
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let enc = cmdBuf.makeRenderCommandEncoder(descriptor: pass) else { return }
              
        let payloads = payloadBuf.contents().bindMemory(to: SpatialPayload.self, capacity: kMaxChannels)
        for i in 0..<kMaxChannels {
            let pos = state.channelPositions[i] ?? SIMD3<Float>(0, 0, 0)
            let scale = 0.02 + Float(state.channelVolumes[i]) * 0.05
            payloads[i] = SpatialPayload(position: pos, scale: scale)
        }
        
        enc.setRenderPipelineState(pso)
        enc.setMeshBuffer(payloadBuf, offset: 0, index: 0)
        
        let threadsPerMeshThreadgroup = MTLSizeMake(64, 1, 1)
        let threadsPerObjectThreadgroup = MTLSizeMake(1, 1, 1)
        let threadgroupsPerGrid = MTLSizeMake(kMaxChannels, 1, 1)
        
        enc.drawMeshThreadgroups(threadgroupsPerGrid, threadsPerObjectThreadgroup: threadsPerObjectThreadgroup, threadsPerMeshThreadgroup: threadsPerMeshThreadgroup)
        
        enc.endEncoding()
        cmdBuf.present(drawable)
        cmdBuf.commit()
    }
}
#endif
