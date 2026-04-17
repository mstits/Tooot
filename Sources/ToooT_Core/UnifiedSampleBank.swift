/*
 *  NextGenTracker (LegacyTracker 2026)
 *  Copyright (c) 2026. All rights reserved.
 *  Transitioning legacy tracker logic to Swift 6.
 */

import Foundation
import Accelerate
import AVFoundation

/// Defines a massive scale sample library bank mapped directly into Unified Memory Architecture (UMA).
/// Supports Stereo Interleaved samples for 2026 Professional Workflows.
public final class UnifiedSampleBank: @unchecked Sendable {

    /// Unsafe contiguous mutable pointer backing the 128MB UMA limit
    public let samplePointer: UnsafeMutablePointer<Float>
    public let totalSamples: Int

    /// Bump pointer for dynamic allocations (track freeze, recording, live sample synthesis).
    /// Parsers use explicit offsets so they never collide with `reserve(count:)`
    /// — but anything writing new content at runtime should go through this API.
    private var dynamicBase: Int = 0
    private let dynamicBaseLock = NSLock()

    public init(capacity: Int = 32_000_000) {
        self.totalSamples = capacity

        // Allocate contiguous float slab.
        self.samplePointer = .allocate(capacity: capacity)
        self.samplePointer.initialize(repeating: 0.0, count: capacity)
        // Parsers typically occupy the low half; reserve the upper half for dynamic writes
        // to keep round-trip-loaded samples stable across freeze/unfreeze cycles.
        self.dynamicBase = capacity / 2
    }

    deinit {
        samplePointer.deallocate()
    }

    public func overwriteRegion(offset: Int, data: [Float]) {
        guard offset + data.count <= totalSamples else { return }
        data.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress {
                vDSP_mmov(base, samplePointer.advanced(by: offset), vDSP_Length(data.count), 1, vDSP_Length(data.count), vDSP_Length(data.count))
            }
        }
    }

    /// Reserves `count` contiguous Float slots in the dynamic half of the bank.
    /// Returns the base offset, or `nil` if the bank is exhausted.
    public func reserve(count: Int) -> Int? {
        guard count > 0 else { return nil }
        dynamicBaseLock.lock()
        defer { dynamicBaseLock.unlock() }
        let start = dynamicBase
        let end   = start + count
        guard end <= totalSamples else { return nil }
        dynamicBase = end
        return start
    }
    
    /// Modern 2026 Importer: Handles MP3, AAC, ALAC, WAV, AIFF using hardware-accelerated transcoding.
    public func load(from url: URL, offset: Int = 0) async throws {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return }
        
        // Output Format: Stereo Float32 Interleaved (Standard for ToooT Engine)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 2
        ]
        
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(output)
        reader.startReading()
        
        var currentOffset = offset
        while reader.status == .reading {
            if let sampleBuffer = output.copyNextSampleBuffer(),
               let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                
                let length = CMBlockBufferGetDataLength(blockBuffer)
                let frameCount = length / 4 // 4 bytes per float
                let tempBuffer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
                defer { tempBuffer.deallocate() }
                
                CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: tempBuffer)
                
                if currentOffset + frameCount <= totalSamples {
                    vDSP_mmov(tempBuffer, samplePointer.advanced(by: currentOffset), vDSP_Length(frameCount), 1, vDSP_Length(frameCount), vDSP_Length(frameCount))
                    currentOffset += frameCount
                }
            } else {
                break
            }
        }
    }
}
