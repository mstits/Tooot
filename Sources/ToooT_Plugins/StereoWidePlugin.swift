/*
 *  PROJECT ToooT (ToooT_Plugins)
 *  Copyright (c) 2026 Apple Core Audio / Pro Apps Division.
 *  AUv3 Stereo Wide Plugin.
 */

import Foundation
import AVFoundation
import Accelerate
import ToooT_Core

public class StereoWidePlugin: ToooTBaseEffect {
    private let scratchL: UnsafeMutablePointer<Float>
    private let scratchR: UnsafeMutablePointer<Float>
    private let maxFrames: Int = 4096
    
    public override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        scratchL = .allocate(capacity: maxFrames)
        scratchL.initialize(repeating: 0, count: maxFrames)
        scratchR = .allocate(capacity: maxFrames)
        scratchR.initialize(repeating: 0, count: maxFrames)
        try super.init(componentDescription: componentDescription, options: options)
    }
    
    deinit {
        scratchL.deallocate()
        scratchR.deallocate()
    }
    
    public override var internalRenderBlock: AUInternalRenderBlock {
        let sL = scratchL
        let sR = scratchR
        return { actionFlags, timestamp, frameCount, outputBusNumber, outputData, renderEvent, pullInputBlock in
            let frames = Int(frameCount)
            let bufferList = UnsafeMutableAudioBufferListPointer(outputData)
            
            if bufferList.count >= 2 {
                if let destL = bufferList[0].mData?.assumingMemoryBound(to: Float.self),
                   let destR = bufferList[1].mData?.assumingMemoryBound(to: Float.self) {
                    
                    // Basic Stereo Widening: L' = L*1.5 - R*0.5, R' = R*1.5 - L*0.5
                    // Uses vDSP for maximum efficiency on Apple Silicon
                    var widenFactor: Float = 1.5
                    var crossFactor: Float = -0.5
                    
                    // Save originals into scratch before writing any output
                    // sL = copy of original left, sR = copy of original right
                    vDSP_mmov(destL, sL, vDSP_Length(frames), 1, 1, 1)
                    vDSP_mmov(destR, sR, vDSP_Length(frames), 1, 1, 1)

                    // L' = L*1.5 + R*(-0.5) using originals
                    vDSP_vsmul(sL, 1, &widenFactor, destL, 1, vDSP_Length(frames))
                    var neg = crossFactor
                    vDSP_vsma(sR, 1, &neg, destL, 1, destL, 1, vDSP_Length(frames))

                    // R' = R*1.5 + L*(-0.5) using originals
                    vDSP_vsmul(sR, 1, &widenFactor, destR, 1, vDSP_Length(frames))
                    vDSP_vsma(sL, 1, &neg, destR, 1, destR, 1, vDSP_Length(frames))
                }
            }
            return noErr
        }
    }
}
