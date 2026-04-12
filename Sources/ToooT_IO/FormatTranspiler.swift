/*
 *  NextGenTracker (LegacyTracker 2026)
 *  Copyright (c) 2026. All rights reserved.
 *  Transitioning legacy tracker logic to Swift 6.
 */

import Foundation
import Accelerate
import ToooT_Core

public enum TrackerFormat {
    case mod, xm, it, unknown
}

/// Advanced Multi-Format Transpiler for 2026.
public struct FormatTranspiler {
    public let sourceURL: URL?
    public init(sourceURL: URL? = nil) { self.sourceURL = sourceURL }
    
    public func detectFormat(data: Data) -> TrackerFormat {
        guard data.count > 1084 else { return .unknown }
        if data.count > 17 && String(data: data[0..<17], encoding: .ascii) == "Extended Module: " { return .xm }
        if data.count > 4 && String(data: data[0..<4], encoding: .ascii) == "IMPM" { return .it }
        let magic = String(data: data[1080..<1084], encoding: .ascii) ?? ""
        let modMagic = ["M.K.", "M!K!", "FLT4", "4CHN", "6CHN", "8CHN"]
        if modMagic.contains(magic) { return .mod }
        return .unknown
    }

    public func parseInstruments(from url: URL) -> [Int: Instrument] {
        guard let fileData = try? Data(contentsOf: url) else { return [:] }
        let format = detectFormat(data: fileData)
        switch format {
        case .xm: return parseXMInstruments(data: fileData)
        case .it: return parseITInstruments(data: fileData)
        default: return parseMODInstruments(data: fileData)
        }
    }
    
    private func parseMODInstruments(data: Data) -> [Int: Instrument] {
        var instrumentMap = [Int: Instrument]()
        var currentBankOffset = 0
        for i in 0..<31 {
            let offset = 20 + (i * 30)
            guard offset + 30 <= data.count else { break }
            let nameData = data[offset..<(offset + 22)]
            let parsedName = String(data: nameData, encoding: .ascii)?.replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let lengthInBytes = Int(UInt16(data[offset + 22]) << 8 | UInt16(data[offset + 23])) * 2
            // offset+24: finetune nibble (lower 4 bits), signed -8…+7.
            // Values 0-7 are positive; 8-15 are negative (8→-8, 9→-7, …, 15→-1).
            let rawFine = Int(data[offset + 24] & 0x0F)
            let finetune = Int8(rawFine > 7 ? rawFine - 16 : rawFine)
            let defaultVol = Float(data[offset + 25]) / 64.0
            let loopStart = Int(UInt16(data[offset + 26]) << 8 | UInt16(data[offset + 27])) * 2
            let loopLen = Int(UInt16(data[offset + 28]) << 8 | UInt16(data[offset + 29])) * 2

            var inst = Instrument()
            inst.setName(parsedName.isEmpty ? "Instrument \(i+1)" : parsedName)
            inst.defaultVolume = defaultVol

            var region = SampleRegion(offset: currentBankOffset, length: lengthInBytes)
            region.finetune = finetune
            if loopLen > 2 {
                region.loopType = .classic; region.loopStart = loopStart; region.loopLength = loopLen
                if loopStart + loopLen > region.length {
                    region.length = loopStart + loopLen
                }
            }
            inst.addRegion(region)
            instrumentMap[i + 1] = inst
            currentBankOffset += lengthInBytes
        }
        return instrumentMap
    }
    
    private func parseXMInstruments(data: Data) -> [Int: Instrument] {
        var instrumentMap = [Int: Instrument]()
        let numInstruments = Int(data[70]) | (Int(data[71]) << 8)
        // XM header size at offset 60 (4-byte LE)
        let xmHeaderSize = Int(data[60]) | (Int(data[61]) << 8) | (Int(data[62]) << 16) | (Int(data[63]) << 24)
        var offset = 60 + xmHeaderSize
        let numPatterns = Int(data[68]) | (Int(data[69]) << 8)
        for _ in 0..<numPatterns {
            guard offset + 9 <= data.count else { break }
            let patHeaderLen = Int(data[offset]) | (Int(data[offset+1]) << 8) | (Int(data[offset+2]) << 16) | (Int(data[offset+3]) << 24)
            let packedSize = Int(data[offset + 7]) | (Int(data[offset + 8]) << 8)
            offset += patHeaderLen + packedSize
        }
        var currentBankOffset = 0
        for i in 1...numInstruments {
            guard offset + 4 <= data.count else { break }
            let instSize = Int(data[offset]) | (Int(data[offset+1]) << 8)
            let nameData = data[offset+4..<offset+26]
            let name = String(data: nameData, encoding: .ascii)?.replacingOccurrences(of: "\0", with: "") ?? "XM Inst \(i)"
            let numSamples = Int(data[offset+27])
            var inst = Instrument()
            inst.setName(name)
            if numSamples > 0 {
                var sHeader = offset + instSize
                for _ in 0..<numSamples {
                    let sLen      = Int(data[sHeader])   | (Int(data[sHeader+1]) << 8) | (Int(data[sHeader+2]) << 16) | (Int(data[sHeader+3]) << 24)
                    let loopStart = Int(data[sHeader+4]) | (Int(data[sHeader+5]) << 8) | (Int(data[sHeader+6]) << 16) | (Int(data[sHeader+7]) << 24)
                    let loopLen   = Int(data[sHeader+8]) | (Int(data[sHeader+9]) << 8) | (Int(data[sHeader+10]) << 16) | (Int(data[sHeader+11]) << 24)
                    let sampleType = data[sHeader + 14]
                    let is16bit    = (sampleType & 0x10) != 0
                    let loopType   = sampleType & 0x03  // 0=none, 1=forward, 2=ping-pong
                    let lenAdded   = is16bit ? sLen / 2 : sLen
                    var region = SampleRegion(offset: currentBankOffset, length: lenAdded)
                    if loopType > 0 && loopLen > 0 {
                        region.loopType   = loopType == 2 ? .pingPong : .classic
                        region.loopStart  = is16bit ? loopStart / 2 : loopStart
                        region.loopLength = is16bit ? loopLen   / 2 : loopLen
                    }
                    inst.addRegion(region)
                    currentBankOffset += lenAdded
                    sHeader += 40
                }
            }
            instrumentMap[i] = inst
            offset += instSize + (numSamples * 40)
        }
        return instrumentMap
    }
    
    private func parseITInstruments(data: Data) -> [Int: Instrument] {
        var instrumentMap = [Int: Instrument]()
        guard data.count > 34 else { return instrumentMap }
        let numInst    = Int(data[32]) | (Int(data[33]) << 8)
        let numSamples = data.count > 36 ? (Int(data[34]) | (Int(data[35]) << 8)) : 0
        guard numInst > 0 else { return instrumentMap }

        let numOrders = Int(data[40]) | (Int(data[41]) << 8)
        var tableOffset = 192 + numOrders

        for i in 1...numInst {
            guard tableOffset + 4 <= data.count else { break }
            let paraPtr = Int(data[tableOffset]) | (Int(data[tableOffset+1]) << 8) | (Int(data[tableOffset+2]) << 16) | (Int(data[tableOffset+3]) << 24)
            tableOffset += 4
            var inst = Instrument()
            if paraPtr > 0 && paraPtr + 32 <= data.count {
                let nameRange = paraPtr + 4 ..< min(paraPtr + 4 + 26, data.count)
                let nameStr = String(data: data[nameRange], encoding: .isoLatin1)?
                    .replacingOccurrences(of: "\0", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? "IT Inst \(i)"
                inst.setName(nameStr)
                inst.defaultVolume = data.count > paraPtr + 17
                    ? Float(data[paraPtr + 17]) / 64.0 : 1.0
            } else {
                inst.setName("IT Inst \(i)")
            }
            instrumentMap[i] = inst
        }

        var sampleTable: [Int] = []
        for _ in 0..<numSamples {
            guard tableOffset + 4 <= data.count else { break }
            let sp = Int(data[tableOffset]) | (Int(data[tableOffset+1]) << 8) | (Int(data[tableOffset+2]) << 16) | (Int(data[tableOffset+3]) << 24)
            sampleTable.append(sp)
            tableOffset += 4
        }

        var currentBankOffset = 0
        for (idx, sp) in sampleTable.enumerated() {
            guard sp + 80 <= data.count else { continue }
            let sLen = Int(data[sp + 16]) | (Int(data[sp+17]) << 8) |
                       (Int(data[sp+18]) << 16) | (Int(data[sp+19]) << 24)
            let flags = data[sp + 14]
            let is16Bit = (flags & 0x02) != 0
            let lenAdded = is16Bit ? sLen / 2 : sLen
            let instID = idx + 1
            if var inst = instrumentMap[instID] {
                inst.addRegion(SampleRegion(offset: currentBankOffset, length: lenAdded))
                instrumentMap[instID] = inst
            }
            currentBankOffset += lenAdded
        }
        return instrumentMap
    }

    public func parseMetadata(from url: URL) -> (orderList: [Int], songLength: Int) {
        guard let data = try? Data(contentsOf: url), data.count >= 1084 else { return ([0], 1) }
        let format = detectFormat(data: data)
        if format == .xm {
            let len = Int(data[64]) | (Int(data[65]) << 8)
            var orders: [Int] = []
            for i in 0..<min(256, len) { orders.append(Int(data[80 + i])) }
            return (orders, len)
        }
        let songLength = max(1, Int(data[950]))
        var orderList: [Int] = []
        for i in 0..<128 { orderList.append(Int(data[952 + i])) }
        return (orderList, songLength)
    }

    public func createSnapshot(from url: URL) throws -> [TrackerEvent] {
        let fileData = try Data(contentsOf: url)
        let format = detectFormat(data: fileData)
        if format == .xm { return try parseXMPatterns(data: fileData) }
        
        var rowMap = [TrackerEvent](repeating: TrackerEvent.empty, count: kMaxChannels * 64 * 100)
        guard fileData.count >= 1084 else { return rowMap }
        
        let magic = String(data: fileData[1080..<1084], encoding: .ascii) ?? ""
        let modChannels: Int
        switch magic {
        case "6CHN": modChannels = 6
        case "8CHN": modChannels = 8
        default:     modChannels = 4
        }
        
        let patternStart = 1084
        let _ = max(1, Int(fileData[950]))  // songLength — used by parseMetadata, not needed here
        var maxPattern = 0
        for i in 0..<128 { if 952 + i < fileData.count { let pat = Int(fileData[952 + i]) & 0x7F; if pat > maxPattern { maxPattern = pat } } }
        
        let rowStride = modChannels * 4
        let patternSize = 64 * rowStride
        
        for p in 0...maxPattern {
            let patternOffset = patternStart + (p * patternSize)
            guard fileData.count >= patternOffset + patternSize else { break }
            for row in 0..<64 {
                let absRow = (p * 64) + row
                for channel in 0..<modChannels {
                    let cellOffset = patternOffset + (row * rowStride) + (channel * 4)
                    let b1 = Int(fileData[cellOffset]), b2 = Int(fileData[cellOffset + 1]), b3 = Int(fileData[cellOffset + 2]), b4 = Int(fileData[cellOffset + 3])
                    let instrument = UInt8((b1 & 0xF0) | ((b3 & 0xF0) >> 4))
                    let period = ((b1 & 0x0F) << 8) | b2
                    let effect = UInt8(b3 & 0x0F), param = UInt8(b4)
                    var type: TrackerEventType = .empty, v1: Float = 0, v2: Float = -1.0
                    if period > 0 { v1 = Float(7093789.2 / Double(period * 2)); type = .noteOn }

                    if type == .empty && effect == 0 && param == 0 && instrument == 0 { continue }
                    // Pattern effects: store in effectCommand/effectParam only.
                    // Do NOT overwrite type if there's a note — let the render block
                    // handle both the note trigger AND the pattern effect via effectCommand.
                    if effect == 0x0B && type != .noteOn { type = .patternJump; v1 = Float(param) }
                    else if effect == 0x0D && type != .noteOn { type = .patternBreak; v1 = Float((param >> 4) * 10 + (param & 0x0F)) }
                    else if effect == 0x0C {
                        if type == .noteOn {
                            // Note + volume: keep the note, pass volume via value2
                            v2 = Float(param) / 64.0
                        } else {
                            // Volume-only command
                            type = .setVolume; v1 = Float(param) / 64.0
                        }
                    }

                    rowMap[absRow * kMaxChannels + channel] = TrackerEvent(type: type, channel: UInt8(channel), instrument: instrument, value1: v1, value2: v2, effectCommand: effect, effectParam: param)
                }
            }
        }
        return rowMap
    }
    
    private func parseXMPatterns(data: Data) throws -> [TrackerEvent] {
        var rowMap = [TrackerEvent](repeating: TrackerEvent.empty, count: kMaxChannels * 64 * 100)
        let numChannels = Int(data[68]) | (Int(data[69]) << 8) // XM stores channel count at 68-69
        let numPatterns = Int(data[70]) | (Int(data[71]) << 8) // Pattern count at 70-71 (not 68-69)
        // XM header size is stored at offset 60 as 4-byte LE
        let xmHeaderSize = Int(data[60]) | (Int(data[61]) << 8) | (Int(data[62]) << 16) | (Int(data[63]) << 24)
        var offset = 60 + xmHeaderSize
        let xmChannels = min(numChannels, kMaxChannels) // Clamp to our max
        for p in 0..<numPatterns {
            guard offset + 9 <= data.count else { break }
            // XM pattern header: 4-byte LE header length
            let headerLen = Int(data[offset]) | (Int(data[offset+1]) << 8) | (Int(data[offset+2]) << 16) | (Int(data[offset+3]) << 24)
            let numRows = Int(data[offset + 5]) | (Int(data[offset + 6]) << 8)
            let packedSize = Int(data[offset + 7]) | (Int(data[offset + 8]) << 8)
            offset += headerLen
            if packedSize > 0 {
                let startOffset = offset
                let actualRows = min(numRows, 64) // Clamp to 64 for our slab
                for row in 0..<actualRows {
                    let absRow = (p * 64) + row
                    for ch in 0..<xmChannels {
                        guard offset < startOffset + packedSize else { break }
                        guard offset < data.count else { break }
                        let b = data[offset]; offset += 1
                        var note: UInt8 = 0, inst: UInt8 = 0, vol: UInt8 = 0, cmd: UInt8 = 0, param: UInt8 = 0
                        if b & 0x80 != 0 {
                            if b & 0x01 != 0 { guard offset < data.count else { break }; note = data[offset]; offset += 1 }
                            if b & 0x02 != 0 { guard offset < data.count else { break }; inst = data[offset]; offset += 1 }
                            if b & 0x04 != 0 { guard offset < data.count else { break }; vol = data[offset]; offset += 1 }
                            if b & 0x08 != 0 { guard offset < data.count else { break }; cmd = data[offset]; offset += 1 }
                            if b & 0x10 != 0 { guard offset < data.count else { break }; param = data[offset]; offset += 1 }
                        } else {
                            guard offset + 4 <= data.count else { break }
                            note = b; inst = data[offset]; vol = data[offset+1]; cmd = data[offset+2]; param = data[offset+3]; offset += 4
                        }
                        if note > 0 {
                            var freq: Float = 0
                            if note < 0xFE {
                                freq = 440.0 * pow(2.0, (Float(note) - 69.0) / 12.0)
                            }
                            rowMap[absRow * kMaxChannels + ch] = TrackerEvent(type: .noteOn, channel: UInt8(ch), instrument: inst, value1: freq, value2: Float(vol)/64.0, effectCommand: cmd, effectParam: param)
                        } else if cmd > 0 || param > 0 {
                            rowMap[absRow * kMaxChannels + ch] = TrackerEvent(type: .empty, channel: UInt8(ch), instrument: inst, value1: 0, value2: -1.0, effectCommand: cmd, effectParam: param)
                        }
                    }
                }
                // Ensure we advance past all packed data even if we didn't consume it all
                offset = startOffset + packedSize
            }
        }
        return rowMap
    }

    public func loadSamples(from url: URL, into engine: AudioEngine) throws {
        let fileData = try Data(contentsOf: url)
        let format = detectFormat(data: fileData)
        if format == .xm {
            try loadXMSamples(data: fileData, bank: engine.sampleBank)
            return
        }
        if format == .it {
            try loadITSamples(data: fileData, into: engine)
            return
        }
        try loadMODSamples(data: fileData, intoBank: engine.sampleBank)
    }

    /// Bank-only variant — no AudioEngine dependency; usable in tests and offline tools.
    public func loadSamples(from url: URL, intoBank bank: UnifiedSampleBank) throws {
        let fileData = try Data(contentsOf: url)
        let format = detectFormat(data: fileData)
        if format == .xm {
            try loadXMSamples(data: fileData, bank: bank)
            return
        }
        if format == .it {
            try loadITSamples(data: fileData, intoBank: bank)
            return
        }
        if format == .mod {
            try loadMODSamples(data: fileData, intoBank: bank)
        }
    }

    private func loadMODSamples(data fileData: Data, intoBank bank: UnifiedSampleBank) throws {
        guard fileData.count >= 1084 else { return }

        let magic = String(data: fileData[1080..<1084], encoding: .ascii) ?? ""
        let modChannels: Int
        switch magic {
        case "6CHN": modChannels = 6
        case "8CHN": modChannels = 8
        default:     modChannels = 4
        }

        var maxPattern = 0
        for i in 0..<128 { if 952 + i < fileData.count { let pat = Int(fileData[952 + i]) & 0x7F; if pat > maxPattern { maxPattern = pat } } }        
        let rowStride = modChannels * 4
        let patternSize = 64 * rowStride
        
        let sampleDataStart = 1084 + ((maxPattern + 1) * patternSize)
        var currentOffset = sampleDataStart
        var currentBankOffset = 0
        for i in 0..<31 {
            let headerOffset = 20 + (i * 30)
            guard headerOffset + 24 <= fileData.count else { break }
            let lengthInBytes = Int(UInt16(fileData[headerOffset + 22]) << 8 | UInt16(fileData[headerOffset + 23])) * 2
            
            if lengthInBytes > 0 && currentOffset < fileData.count {
                let actualLen = min(lengthInBytes, fileData.count - currentOffset)
                var floatData = [Float](repeating: 0.0, count: actualLen)
                fileData.withUnsafeBytes { rawBytes in
                    let src = rawBytes.baseAddress!.advanced(by: currentOffset).assumingMemoryBound(to: Int8.self)
                    vDSP_vflt8(src, 1, &floatData, 1, vDSP_Length(actualLen))
                }
                var scale: Float = 1.0 / 128.0
                floatData.withUnsafeMutableBufferPointer { buf in
                    vDSP_vsmul(buf.baseAddress!, 1, &scale, buf.baseAddress!, 1, vDSP_Length(actualLen))
                }
                bank.overwriteRegion(offset: currentBankOffset, data: floatData)
            }
            currentOffset += lengthInBytes
            currentBankOffset += lengthInBytes
        }
    }

    private func loadXMSamples(data: Data, bank: UnifiedSampleBank) throws {
        // XM header: 60 bytes fixed header
        // Instrument count at offset 0x48 (2 bytes LE)
        guard data.count > 0x3A else { return }
        let instrCount = Int(data[0x48]) | (Int(data[0x49]) << 8)
        var offset = 0x3C + (Int(data[0x3A]) | (Int(data[0x3B]) << 8))  // skip pattern data
        
        // Skip patterns: pattern count at 0x46
        let patCount = Int(data[0x46]) | (Int(data[0x47]) << 8)
        // Each pattern header is a 4-byte LE size + packed data
        var patOffset = 0x3C
        for _ in 0..<patCount {
            guard patOffset + 9 <= data.count else { break }
            let phLen = Int(data[patOffset]) | (Int(data[patOffset+1]) << 8) | (Int(data[patOffset+2]) << 16) | (Int(data[patOffset+3]) << 24)
            let packedSize = Int(data[patOffset + 7]) | (Int(data[patOffset + 8]) << 8)
            patOffset += phLen + packedSize
        }
        offset = patOffset
        
        var currentBankOffset = 0
        for _ in 0..<instrCount {
            guard offset + 4 <= data.count else { break }
            let instrSize = Int(data[offset]) | (Int(data[offset+1]) << 8) |
                            (Int(data[offset+2]) << 16) | (Int(data[offset+3]) << 24)
            guard instrSize > 0, offset + instrSize <= data.count else {
                offset += max(instrSize, 1); continue
            }
            let sampleCount = offset + 27 < data.count
                ? Int(data[offset + 27]) | (Int(data[offset + 28]) << 8) : 0
            
            if sampleCount == 0 { offset += instrSize; continue }
            
            // Sample headers follow instrument header (instrSize bytes from offset)
            let sampleHeaderBase = offset + instrSize
            
            for sampleIdx in 0..<sampleCount {
                let sh = sampleHeaderBase + sampleIdx * 40
                guard sh + 40 <= data.count else { break }
                let sampleLen  = Int(data[sh])|(Int(data[sh+1])<<8)|(Int(data[sh+2])<<16)|(Int(data[sh+3])<<24)
                let loopStart  = Int(data[sh+4])|(Int(data[sh+5])<<8)|(Int(data[sh+6])<<16)|(Int(data[sh+7])<<24)
                let loopLen    = Int(data[sh+8])|(Int(data[sh+9])<<8)|(Int(data[sh+10])<<16)|(Int(data[sh+11])<<24)
                let sampleType = data[sh + 14]  // bit 4 = 16-bit, bits 0-1 = loop type
                let is16bit    = (sampleType & 0x10) != 0
                
                // Sample data follows all sample headers
                let dataOffset = sampleHeaderBase + sampleCount * 40 + (0..<sampleIdx).reduce(0) { acc, j in
                    let jsh = sampleHeaderBase + j * 40
                    let jLen = Int(data[jsh])|(Int(data[jsh+1])<<8)|(Int(data[jsh+2])<<16)|(Int(data[jsh+3])<<24)
                    return acc + jLen
                }
                
                guard sampleLen > 0, dataOffset + sampleLen <= data.count else {
                    let lenAdded = is16bit ? sampleLen / 2 : sampleLen
                    currentBankOffset += lenAdded
                    continue
                }
                
                // XM delta decoding
                var floatData: [Float]
                if is16bit {
                    let count = sampleLen / 2
                    floatData = [Float](repeating: 0, count: count)
                    var acc: Int16 = 0
                    for j in 0..<count {
                        let lo = UInt16(data[dataOffset + j * 2])
                        let hi = UInt16(data[dataOffset + j * 2 + 1])
                        let raw = lo | (hi << 8)
                        let delta = Int16(bitPattern: raw)
                        acc = acc &+ delta
                        floatData[j] = Float(acc) / 32768.0
                    }
                } else {
                    floatData = [Float](repeating: 0, count: sampleLen)
                    var acc: Int8 = 0
                    for j in 0..<sampleLen {
                        let delta = Int8(bitPattern: data[dataOffset + j])
                        acc = acc &+ delta
                        floatData[j] = Float(acc) / 128.0
                    }
                }
                
                bank.overwriteRegion(offset: currentBankOffset, data: floatData)
                let lenAdded = is16bit ? sampleLen / 2 : sampleLen
                // Store loop info for the region (used by instrument mapper)
                _ = (loopStart, loopLen) // Silence unused variable warnings — data feeds into instrument regions
                currentBankOffset += lenAdded
            }
            offset += instrSize
        }
    }

    private func loadITSamples(data: Data, into engine: AudioEngine) throws {
        guard data.count > 40 else { return }
        let numInst    = data.count > 34 ? (Int(data[32]) | (Int(data[33]) << 8)) : 0
        let numSamples = data.count > 36 ? (Int(data[34]) | (Int(data[35]) << 8)) : 0
        let numOrders  = data.count > 42 ? (Int(data[40]) | (Int(data[41]) << 8)) : 0
        guard numSamples > 0 else { return }

        let sampleTableOffset = 192 + numOrders + numInst * 4
        var currentBankOffset = 0

        for s in 0..<numSamples {
            let ptrOff = sampleTableOffset + s * 4
            guard ptrOff + 4 <= data.count else { break }
            let sp = Int(data[ptrOff]) | (Int(data[ptrOff+1]) << 8) |
                     (Int(data[ptrOff+2]) << 16) | (Int(data[ptrOff+3]) << 24)
            guard sp > 0, sp + 80 <= data.count else { continue }

            let sLen     = Int(data[sp+16]) | (Int(data[sp+17]) << 8) |
                           (Int(data[sp+18]) << 16) | (Int(data[sp+19]) << 24)
            let flags    = data[sp + 14]
            let is16Bit  = (flags & 0x02) != 0
            let isSigned = (flags & 0x01) != 0
            let dataPtr  = Int(data[sp+72]) | (Int(data[sp+73]) << 8) |
                           (Int(data[sp+74]) << 16) | (Int(data[sp+75]) << 24)

            let lenAdded = is16Bit ? sLen / 2 : sLen

            guard sLen > 0, dataPtr > 0, dataPtr + sLen <= data.count else {
                currentBankOffset += lenAdded
                continue
            }

            var floatData: [Float]
            if is16Bit {
                let count = sLen / 2
                floatData = [Float](repeating: 0, count: count)
                for j in 0..<count {
                    let lo = UInt16(data[dataPtr + j * 2])
                    let hi = UInt16(data[dataPtr + j * 2 + 1])
                    let raw = lo | (hi << 8)
                    floatData[j] = isSigned
                        ? Float(Int16(bitPattern: raw)) / 32768.0
                        : Float(Int32(raw) - 32768) / 32768.0
                }
            } else {
                floatData = [Float](repeating: 0, count: sLen)
                for j in 0..<sLen {
                    let raw = data[dataPtr + j]
                    floatData[j] = isSigned
                        ? Float(Int8(bitPattern: raw)) / 128.0
                        : Float(Int16(raw) - 128) / 128.0
                }
            }

            engine.sampleBank.overwriteRegion(offset: currentBankOffset, data: floatData)
            currentBankOffset += lenAdded
        }
    }

    /// Bank-only IT loader — mirrors loadITSamples(data:into:engine:) without the AudioEngine dependency.
    private func loadITSamples(data: Data, intoBank bank: UnifiedSampleBank) throws {
        guard data.count > 40 else { return }
        let numInst    = data.count > 34 ? (Int(data[32]) | (Int(data[33]) << 8)) : 0
        let numSamples = data.count > 36 ? (Int(data[34]) | (Int(data[35]) << 8)) : 0
        let numOrders  = data.count > 42 ? (Int(data[40]) | (Int(data[41]) << 8)) : 0
        guard numSamples > 0 else { return }

        let sampleTableOffset = 192 + numOrders + numInst * 4
        var currentBankOffset = 0

        for s in 0..<numSamples {
            let ptrOff = sampleTableOffset + s * 4
            guard ptrOff + 4 <= data.count else { break }
            let sp = Int(data[ptrOff]) | (Int(data[ptrOff+1]) << 8) |
                     (Int(data[ptrOff+2]) << 16) | (Int(data[ptrOff+3]) << 24)
            guard sp > 0, sp + 80 <= data.count else { continue }

            let sLen     = Int(data[sp+16]) | (Int(data[sp+17]) << 8) |
                           (Int(data[sp+18]) << 16) | (Int(data[sp+19]) << 24)
            let flags    = data[sp + 14]
            let is16Bit  = (flags & 0x02) != 0
            let isSigned = (flags & 0x01) != 0
            let dataPtr  = Int(data[sp+72]) | (Int(data[sp+73]) << 8) |
                           (Int(data[sp+74]) << 16) | (Int(data[sp+75]) << 24)
            let lenAdded = is16Bit ? sLen / 2 : sLen

            guard sLen > 0, dataPtr > 0, dataPtr + sLen <= data.count else {
                currentBankOffset += lenAdded
                continue
            }

            var floatData: [Float]
            if is16Bit {
                let count = sLen / 2
                floatData = [Float](repeating: 0, count: count)
                for j in 0..<count {
                    let lo = UInt16(data[dataPtr + j * 2])
                    let hi = UInt16(data[dataPtr + j * 2 + 1])
                    let raw = lo | (hi << 8)
                    floatData[j] = isSigned
                        ? Float(Int16(bitPattern: raw)) / 32768.0
                        : Float(Int32(raw) - 32768) / 32768.0
                }
            } else {
                floatData = [Float](repeating: 0, count: sLen)
                for j in 0..<sLen {
                    let raw = data[dataPtr + j]
                    floatData[j] = isSigned
                        ? Float(Int8(bitPattern: raw)) / 128.0
                        : Float(Int16(raw) - 128) / 128.0
                }
            }
            bank.overwriteRegion(offset: currentBankOffset, data: floatData)
            currentBankOffset += lenAdded
        }
    }
}
