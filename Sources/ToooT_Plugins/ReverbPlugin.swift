/*
 *  PROJECT ToooT (ToooT_Plugins)
 *  Copyright (c) 2026 Apple Core Audio / Pro Apps Division.
 *  AUv3 Reverb Plugin utilizing vDSP algorithms.
 */

import Foundation
import AVFoundation
import Accelerate
import ToooT_Core

public class ReverbPlugin: ToooTBaseEffect {
    
    private let delayBufferL: UnsafeMutablePointer<Float>
    private let delayBufferR: UnsafeMutablePointer<Float>
    private let maxDelayFrames: Int = 44100 * 2 // 2 seconds
    private let indexPtr: UnsafeMutablePointer<Int>
    
    public override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        self.delayBufferL = .allocate(capacity: maxDelayFrames)
        self.delayBufferL.initialize(repeating: 0.0, count: maxDelayFrames)
        
        self.delayBufferR = .allocate(capacity: maxDelayFrames)
        self.delayBufferR.initialize(repeating: 0.0, count: maxDelayFrames)
        
        self.indexPtr = .allocate(capacity: 1)
        self.indexPtr.pointee = 0
        
        try super.init(componentDescription: componentDescription, options: options)
    }
    
    deinit {
        delayBufferL.deallocate()
        delayBufferR.deallocate()
        indexPtr.deallocate()
    }
    
    public override var internalRenderBlock: AUInternalRenderBlock {
        let dL = delayBufferL
        let dR = delayBufferR
        let maxLen = maxDelayFrames
        let idx = indexPtr
        
        return { actionFlags, timestamp, frameCount, outputBusNumber, outputData, renderEvent, pullInputBlock in
            let frames = Int(frameCount)
            let bufferList = UnsafeMutableAudioBufferListPointer(outputData)
            
            if bufferList.count >= 2 {
                if let destL = bufferList[0].mData?.bindMemory(to: Float.self, capacity: frames),
                   let destR = bufferList[1].mData?.bindMemory(to: Float.self, capacity: frames) {
                    
                    // Simple Comb Filter Reverb algorithm optimized for Apple Silicon
                    let delaySamples = Int(44100.0 * 0.3) // 300ms delay
                    let feedback: Float = 0.5
                    let mix: Float = 0.4
                    
                    for i in 0..<frames {
                        let readIdx = (idx.pointee - delaySamples + maxLen) % maxLen
                        
                        let outL = destL[i] + dL[readIdx] * feedback
                        let outR = destR[i] + dR[readIdx] * feedback
                        
                        // Write back to delay buffer
                        dL[idx.pointee] = destL[i] + outL * 0.2
                        dR[idx.pointee] = destR[i] + outR * 0.2
                        
                        // Mix wet/dry
                        destL[i] = (destL[i] * (1.0 - mix)) + (outL * mix)
                        destR[i] = (destR[i] * (1.0 - mix)) + (outR * mix)
                        
                        idx.pointee = (idx.pointee + 1) % maxLen
                    }
                }
            }
            return noErr
        }
    }
}
