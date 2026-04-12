/*
 *  PROJECT ToooT (ToooT_IO)
 *  Copyright (c) 2026 Apple Core Audio / Pro Apps Division.
 *  Native MAD Format Writer.
 */

import Foundation
import ToooT_Core
import Accelerate

public struct MADWriter {
    public init() {}
    
    /// Serializes song data back to disk in the MAD format.
    public func write(events: UnsafeMutablePointer<TrackerEvent>,
                      eventCount: Int,
                      instruments: [Int: Instrument],
                      orderList: [Int],
                      songLength: Int,
                      sampleBank: UnifiedSampleBank?,
                      songTitle: String = "Untitled Song",
                      pluginStates: [String: Data] = [:],
                      to destinationURL: URL) throws {

        var data = Data(repeating: 0, count: 1296)

        // 1. Signature
        data.replaceSubrange(0..<4, with: "MADK".data(using: .ascii)!)

        // 2. Title — use the actual song title, not a hardcoded placeholder.
        let titleData = songTitle.prefix(32).data(using: .ascii) ?? Data()
        data.replaceSubrange(4..<4+min(titleData.count, 32), with: titleData.prefix(32))
        
        // 3. Metadata
        let totalRows = eventCount / kMaxChannels
        let numPat = (totalRows + 63) / 64
        let sortedKeys = instruments.keys.sorted()
        let numInstru = sortedKeys.last ?? 0
        
        // Determine actual channel count by scanning for non-empty events
        var maxChannel = 7  // minimum 8 channels
        for idx in 0..<eventCount {
            let ev = events[idx]
            if ev.type != .empty || ev.effectCommand > 0 {
                let ch = idx % kMaxChannels
                maxChannel = max(maxChannel, ch)
            }
        }
        let writeChannels = min(maxChannel + 1, kMaxChannels)
        
        data[292] = UInt8(clamping: numPat)
        data[293] = UInt8(clamping: writeChannels)
        data[295] = UInt8(clamping: numInstru)
        
        // 4. Order List
        for i in 0..<min(orderList.count, 999) {
            data[297 + i] = UInt8(clamping: orderList[i])
        }
        
        // 5. Pattern Data (5 bytes per cell)
        for p in 0..<numPat {
            for row in 0..<64 {
                for ch in 0..<writeChannels {
                    let index = (p * 64 + row) * kMaxChannels + ch
                    if index < eventCount {
                        let event = events[index]
                        var note: UInt8 = 0
                        if event.type == .noteOn && event.value1 > 0 {
                            note = UInt8(clamping: Int(round(12.0 * log2(Double(event.value1) / 440.0) + 69.0)))
                        } else if event.type == .noteOff { note = 0xFE }
                        
                        let vol: UInt8 = event.value2 >= 0 ? UInt8(clamping: Int(event.value2 * 64.0)) : 0xFF
                        data.append(contentsOf: [note, event.instrument, vol, event.effectCommand, event.effectParam])
                    } else {
                        data.append(contentsOf: [0, 0, 0xFF, 0, 0])
                    }
                }
            }
        }
        
        // 6. Instrument Metadata & Sample Data
        var sampleData = Data()
        guard numInstru > 0 else {
            try data.write(to: destinationURL)
            return
        }
        for i in 1...numInstru {
            var instHeader = Data(repeating: 0, count: 232)
            if let inst = instruments[i] {
                // Name (32 bytes)
                withUnsafePointer(to: inst.name) { ptr in
                    let nameData = Data(bytes: ptr, count: 32)
                    instHeader.replaceSubrange(0..<32, with: nameData)
                }
                
                if inst.regionCount > 0 {
                    let reg = inst.regions.0
                    let sLen = reg.length
                    // Sample Length (4 bytes at offset 32)
                    instHeader[32] = UInt8(sLen & 0xFF)
                    instHeader[33] = UInt8((sLen >> 8) & 0xFF)
                    instHeader[34] = UInt8((sLen >> 16) & 0xFF)
                    instHeader[35] = UInt8((sLen >> 24) & 0xFF)
                    
                    // Loop info (offsets 36-43)
                    instHeader[36] = UInt8(reg.loopStart & 0xFF)
                    instHeader[37] = UInt8((reg.loopStart >> 8) & 0xFF)
                    instHeader[38] = UInt8((reg.loopStart >> 16) & 0xFF)
                    instHeader[39] = UInt8((reg.loopStart >> 24) & 0xFF)
                    instHeader[40] = UInt8(reg.loopLength & 0xFF)
                    instHeader[41] = UInt8((reg.loopLength >> 8) & 0xFF)
                    instHeader[42] = UInt8((reg.loopLength >> 16) & 0xFF)
                    instHeader[43] = UInt8((reg.loopLength >> 24) & 0xFF)

                    // Finetune: write to both offset 44 (MAD) and offset 24 (MOD-compatible)
                    // lower nibble stores the signed -8…+7 value using two's-complement nibble encoding.
                    let rawFine: Int
                    if reg.finetune < 0 { rawFine = Int(reg.finetune) + 16 }   // -8→8 … -1→15
                    else                { rawFine = Int(reg.finetune) }          //  0→0 …  7→7
                    let nibble = UInt8(rawFine & 0x0F)
                    instHeader[44] = nibble
                    instHeader[24] = nibble // Byte 24 per manifest requirement
                    instHeader[46] = reg.isStereo ? 1 : 0
                    
                    var lType: UInt8 = 0
                    if reg.loopType == .classic { lType = 1 }
                    else if reg.loopType == .pingPong { lType = 2 }
                    instHeader[47] = lType
                    
                    // Append samples to the global sampleData block
                    if let bank = sampleBank {
                        let sampleCount = reg.isStereo ? sLen * 2 : sLen
                        let ptr = bank.samplePointer.advanced(by: reg.offset)
                        
                        // Convert Float32 -> Int16 for MAD format
                        var pcm = [Int16](repeating: 0, count: sampleCount)
                        var scale = Float(32767.0)
                        
                        // Use a temporary buffer to avoid mutating the live bank during scaling
                        let floatBuf = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
                        defer { floatBuf.deallocate() }
                        
                        memcpy(floatBuf, ptr, sampleCount * MemoryLayout<Float>.size)
                        vDSP_vsmul(floatBuf, 1, &scale, floatBuf, 1, vDSP_Length(sampleCount))
                        vDSP_vfix16(floatBuf, 1, &pcm, 1, vDSP_Length(sampleCount))
                        
                        pcm.withUnsafeBufferPointer { buf in
                            sampleData.append(Data(buffer: buf))
                        }
                    }
                }
            }
            data.append(instHeader)
        }
        
        data.append(sampleData)

        // 7. AUv3 Plugin State Trailer — optional JSON chunk tagged "TOOO".
        // Format: [4-byte tag "TOOO"] [4-byte LE length] [JSON bytes]
        // MADParser checks for this tag after the sample block and restores pluginStates.
        if !pluginStates.isEmpty {
            // Encode each state value as base64 so the JSON stays UTF-8 clean.
            let encodable = pluginStates.mapValues { $0.base64EncodedString() }
            if let jsonData = try? JSONEncoder().encode(encodable) {
                data.append(contentsOf: "TOOO".utf8)
                let len = UInt32(jsonData.count).littleEndian
                withUnsafeBytes(of: len) { data.append(contentsOf: $0) }
                data.append(jsonData)
            }
        }

        try data.write(to: destinationURL)
    }
}

