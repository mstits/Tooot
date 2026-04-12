import Foundation
import ScreenCaptureKit
import AVFoundation
import Combine
import VideoToolbox

/// Global Actor for the Recorder Engine to ensure strict serial processing of media buffers.
@globalActor public actor RecorderActor {
    public static let shared = RecorderActor()
}

@RecorderActor
public final class RecorderManager: NSObject, SCStreamDelegate, SCStreamOutput {
    public static let shared = RecorderManager()
    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var isRecording = false
    private var startTime: CMTime?
    
    // Configuration Constants
    private let videoSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.hevc,
        AVVideoWidthKey: 1920,
        AVVideoHeightKey: 1080,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: 10_000_000,
            AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String
        ]
    ]
    
    private let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC_HE,
        AVSampleRateKey: 44100,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 128000
    ]

    public func startCapture(window: SCWindow, outputURL: URL) async throws {
        // 1. Create SCContentFilter for specific window and process audio
        let filter = SCContentFilter(desktopIndependentWindow: window)
        
        let config = SCStreamConfiguration()
        config.width = 1920
        config.height = 1080
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.capturesAudio = true

        // 2. Setup AVAssetWriter
        assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput?.expectsMediaDataInRealTime = true
        
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput?.expectsMediaDataInRealTime = true
        
        if assetWriter!.canAdd(videoInput!) { assetWriter!.add(videoInput!) }
        if assetWriter!.canAdd(audioInput!) { assetWriter!.add(audioInput!) }
        
        assetWriter!.startWriting()
        
        // 3. Setup and start SCStream
        stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream!.addStreamOutput(self, type: .screen, sampleHandlerQueue: nil)
        try stream!.addStreamOutput(self, type: .audio, sampleHandlerQueue: nil)
        
        try await stream!.startCapture()
        isRecording = true
    }

    public func stopCapture() async throws {
        isRecording = false
        try await stream?.stopCapture()
        
        if let assetWriter = assetWriter {
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            await assetWriter.finishWriting()
        }
        
        stream = nil
        assetWriter = nil
        startTime = nil
    }
}

struct SendableSampleBuffer: @unchecked Sendable {
    let buffer: CMSampleBuffer
}

extension RecorderManager {
    // MARK: - SCStreamOutput
    
    nonisolated public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let wrapped = SendableSampleBuffer(buffer: sampleBuffer)
        Task { @RecorderActor [wrapped] in
            guard isRecording, let assetWriter = assetWriter else { return }
            let safeBuffer = wrapped.buffer
            
            if startTime == nil {
                startTime = CMSampleBufferGetPresentationTimeStamp(safeBuffer)
                assetWriter.startSession(atSourceTime: startTime!)
            }
            
            switch type {
            case .screen:
                if videoInput?.isReadyForMoreMediaData == true {
                    videoInput?.append(safeBuffer)
                }
            case .audio, .microphone:
                if audioInput?.isReadyForMoreMediaData == true {
                    audioInput?.append(safeBuffer)
                }
            @unknown default:
                break
            }
        }
    }
}