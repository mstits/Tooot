/*
 *  PROJECT ToooT (ToooT_Plugins)
 *  Copyright (c) 2026 Apple Core Audio / Pro Apps Division.
 *  AUv3 Modernization of legacy FillPlugs.
 */

import Foundation
import AVFoundation
import ToooT_Core

/// Base class for all modernized LegacyTracker effects.
open class ToooTBaseEffect: AUAudioUnit {
    
    // Parameter Tree for DAW Automation
    private var _parameterTree: AUParameterTree?
    open override var parameterTree: AUParameterTree? {
        get { return _parameterTree }
        set { _parameterTree = newValue }
    }
    
    public override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)
        
        // Initialize high-resolution parameters natively
        setupParameters()
    }
    
    private func setupParameters() {
        let mix = AUParameterTree.createParameter(withIdentifier: "mix", name: "Wet/Dry Mix", address: 0, min: 0, max: 1, unit: .generic, unitName: nil, flags: [.flag_IsReadable, .flag_IsWritable], valueStrings: nil, dependentParameters: nil)
        
        self.parameterTree = AUParameterTree.createTree(withChildren: [mix])
    }
    
    open override var internalRenderBlock: AUInternalRenderBlock {
        return { actionFlags, timestamp, frameCount, outputBusNumber, outputData, renderEvent, pullInputBlock in
            // Default passthrough logic for base class
            return noErr
        }
    }
}
