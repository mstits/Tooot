/*
 *  PROJECT ToooT (ToooT_UI)
 *  Copyright (c) 2026 Apple Core Audio / Pro Apps Division.
 */

import MetalKit
import ToooT_Core
import CoreGraphics
import Darwin
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#endif

// MARK: - Uniform struct (must match Metal shader layout byte-for-byte)

struct PatternScrollUniforms {
    var fractionalRowOffset: Float
    var currentEngineRow:    Float
    var totalRows:           UInt32
    var totalChannels:       UInt32
    var visibleRows:         UInt32
    var cursorChannel:       UInt32
    var cursorRow:           UInt32
    var cellWidth:           Float
    var cellHeight:          Float
    var channelOffset:       Float
}

// MARK: - Renderer

public final class MetalPatternRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    private let device:        MTLDevice
    private let commandQueue:  MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?
    nonisolated(unsafe) var engineStatePtr: UnsafeMutablePointer<EngineSharedState>?
    private var frontBuffer: MTLBuffer
    private var backBuffer:  MTLBuffer
    private let kTotalRows:    Int = 64
    private let kVisibleRows:  Int = 23
    private let kChannelWidth: CGFloat = 120.0
    nonisolated(unsafe) var cursorX: UInt32 = 0
    nonisolated(unsafe) var cursorY: UInt32 = 0
    nonisolated(unsafe) var horizontalScrollX: Float = 0
    nonisolated(unsafe) var currentPattern: Int = 0
    nonisolated(unsafe) var textureInvalidationTrigger: Int = 0
    nonisolated(unsafe) var eventsPtr: UnsafeMutablePointer<TrackerEvent>?
    private let machNumer: Double
    private let machDenom: Double
    private var lastPackedPattern: Int = -1
    private var lastPackedTrigger: Int = -1
    nonisolated(unsafe) private var isPrepared: Bool = false
    nonisolated(unsafe) private var isPacking:  Bool = false

    public init?(engineStatePtr: UnsafeMutablePointer<EngineSharedState>?) {
        let device = MTLCreateSystemDefaultDevice()!
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue
        self.engineStatePtr = engineStatePtr
        var tbInfo = mach_timebase_info_data_t()
        mach_timebase_info(&tbInfo)
        self.machNumer = Double(tbInfo.numer)
        self.machDenom = Double(tbInfo.denom)
        let bufferSize = 64 * kMaxChannels * MemoryLayout<UInt32>.size
        self.frontBuffer = device.makeBuffer(length: bufferSize, options: .storageModeShared)!
        self.backBuffer  = device.makeBuffer(length: bufferSize, options: .storageModeShared)!
        super.init()
        Task { [weak self] in
            let pso = try? await MetalResourceManager.shared.preparePatternPipeline(pixelFormat: .bgra8Unorm)
            self?.pipelineState = pso
            self?.isPrepared = true
        }
    }

    @MainActor
    func syncDisplayState(engineStatePtr: UnsafeMutablePointer<EngineSharedState>?, cursorX: Int, cursorY: Int, horizontalScrollX: Float, currentPattern: Int, textureInvalidationTrigger: Int, eventsPtr: UnsafeMutablePointer<TrackerEvent>) {
        self.engineStatePtr = engineStatePtr
        self.cursorX = UInt32(cursorX); self.cursorY = UInt32(cursorY)
        self.horizontalScrollX = horizontalScrollX; self.currentPattern = currentPattern
        self.textureInvalidationTrigger = textureInvalidationTrigger; self.eventsPtr = eventsPtr
    }

    private func packPatternIfNeeded() {
        let pattern = currentPattern; let trigger = textureInvalidationTrigger; guard let events = eventsPtr, !isPacking, (pattern != lastPackedPattern || trigger != lastPackedTrigger) else { return }
        lastPackedPattern = pattern; lastPackedTrigger = trigger; isPacking = true
        let cellPtr = backBuffer.contents().assumingMemoryBound(to: UInt32.self)
        memset(backBuffer.contents(), 0, 64 * kMaxChannels * 4)
        for row in 0..<64 {
            let rowOffset = (pattern * 64 + row) * kMaxChannels
            for ch in 0..<kMaxChannels {
                let event = events[rowOffset + ch]
                if event.type == .empty && event.effectCommand == 0 { continue }
                var note: UInt32 = 0
                if event.type == .noteOn && event.value1 > 0 { note = UInt32(clamping: Int(12.0 * log2(Double(event.value1) / 440.0) + 69.0)) }
                cellPtr[row * kMaxChannels + ch] = note | (UInt32(event.instrument) << 8) | (UInt32(event.effectCommand) << 16) | (UInt32(event.effectParam) << 24)
            }
        }
        let old = frontBuffer; frontBuffer = backBuffer; backBuffer = old; isPacking = false
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    public func draw(in view: MTKView) {
        guard isPrepared, let pso = pipelineState, let pass = view.currentRenderPassDescriptor, let cmdBuf = commandQueue.makeCommandBuffer(), let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: pass), let drawable = view.currentDrawable else { return }
        packPatternIfNeeded()
        encoder.setRenderPipelineState(pso)
        var frac: Float = 0; var row: Float = 0
        if let es = engineStatePtr?.pointee {
            row = floor(es.playheadPosition); frac = es.playheadPosition - row
            if es.isPlaying != 0 && es.rowDurationSeconds > 0 && es.fractionalRowHostTime > 0 {
                let elapsed = Float(Double(mach_absolute_time() - es.fractionalRowHostTime) * machNumer / machDenom * 1e-9)
                if elapsed < es.rowDurationSeconds { frac = min(frac + elapsed / es.rowDurationSeconds, 0.9999) }
            }
        }
        var uniforms = PatternScrollUniforms(fractionalRowOffset: frac, currentEngineRow: row, totalRows: 64, totalChannels: UInt32(kMaxChannels), visibleRows: 23, cursorChannel: cursorX, cursorRow: cursorY, cellWidth: Float((120.0 / view.drawableSize.width) * 2.0), cellHeight: 2.0 / 23.0, channelOffset: horizontalScrollX)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<PatternScrollUniforms>.size, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<PatternScrollUniforms>.size, index: 0)
        encoder.setFragmentBuffer(frontBuffer, offset: 0, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 24 * kMaxChannels)
        encoder.endEncoding(); cmdBuf.present(drawable); cmdBuf.commit()
    }
}

public struct MetalPatternView: NSViewRepresentable {
    @Bindable var state: PlaybackState; let host: AudioHost?; let timeline: Timeline?
    public func makeCoordinator() -> MetalPatternRenderer { MetalPatternRenderer(engineStatePtr: nil)! }
    public func makeNSView(context: Context) -> MTKView {
        let v = MTKView(); v.delegate = context.coordinator; v.device = MTLCreateSystemDefaultDevice()
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1); v.isPaused = false; v.enableSetNeedsDisplay = false; v.preferredFramesPerSecond = 120
        return v
    }
    public func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.syncDisplayState(engineStatePtr: timeline?.audioEngine?.sharedStatePtr, cursorX: state.cursorX, cursorY: state.cursorY, horizontalScrollX: state.horizontalScrollX, currentPattern: state.currentPattern, textureInvalidationTrigger: state.textureInvalidationTrigger, eventsPtr: state.sequencerData.events)
    }
}
