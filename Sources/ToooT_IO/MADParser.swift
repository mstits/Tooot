/*
 *  PROJECT ToooT (ToooT_IO)
 *  Copyright (c) 2026 Apple Core Audio / Pro Apps Division.
 *  Native MAD + ProTracker MOD Format Parser.
 */

import Foundation
import ToooT_Core
import Accelerate

public struct MADParser {
    public let sourceURL: URL
    public init(sourceURL: URL) { self.sourceURL = sourceURL }

    // MARK: - Public Entry Point

    /// Returns events, instruments, and optionally parsed AUv3 plugin states.
    /// Supports MAD (MADK/MADG/Tooo) and classic ProTracker/FastTracker MOD.
    public func parse(sampleBank: UnifiedSampleBank? = nil) throws -> (UnsafeMutablePointer<TrackerEvent>, [Int: Instrument], [String: Data])? {
        let data = try Data(contentsOf: sourceURL)
        guard data.count > 4 else { return nil }

        // --- MAD format: 4-byte signature at byte 0 ---
        let sig4 = String(data: data[0..<4], encoding: .ascii) ?? ""
        if sig4 == "MADK" || sig4 == "MADG" || sig4 == "Tooo" {
            return try parseMAD(data: data, sampleBank: sampleBank)
        }

        // --- ProTracker / FastTracker MOD: marker at offset 1080 ---
        if data.count >= 1084 {
            let marker = String(data: data[1080..<1084], encoding: .ascii) ?? ""
            if isMODMarker(marker) {
                return try parseMOD(data: data, marker: marker, sampleBank: sampleBank)
            }
        }

        return nil  // unrecognised — caller should show error to user
    }

    // MARK: - MAD Format Parser

    private func parseMAD(data: Data, sampleBank: UnifiedSampleBank?) throws -> (UnsafeMutablePointer<TrackerEvent>, [Int: Instrument], [String: Data])? {
        let rowMap: UnsafeMutablePointer<TrackerEvent> = .allocate(capacity: kMaxChannels * 64 * 100)
        rowMap.initialize(repeating: .empty, count: kMaxChannels * 64 * 100)
        var instMap: [Int: Instrument] = [:]

        var offset = 4 + 32 + 239 + 3 + 8 + 3 + 3
        let numPat    = Int(data[offset])
        let numChn    = Int(data[offset + 1])
        let numInstru = Int(data[offset + 3])
        offset += 5 + 999

        // 1. Pattern Data
        for p in 0..<numPat {
            guard offset + (64 * numChn * 5) <= data.count else { break }
            for row in 0..<64 {
                let absRow = (p * 64) + row
                for ch in 0..<numChn {
                    let cOff = offset + (row * numChn * 5) + (ch * 5)
                    let note = data[cOff], ins = data[cOff + 1], vol = data[cOff + 2]
                    let cmd  = data[cOff + 3], info = data[cOff + 4]
                    if note > 0 || ins > 0 || vol < 0xFF || cmd > 0 {
                        var type: TrackerEventType = .empty; var v1: Float = 0
                        if note > 0 && note < 0xFE {
                            type = .noteOn; v1 = 440.0 * pow(2.0, (Float(note) - 69.0) / 12.0)
                        } else if note == 0xFE { type = .noteOff }
                        if type == .empty || type == .noteOn {
                            switch cmd {
                            case 0x00: if note == 0 { type = .arpeggio }
                            case 0x01, 0x02, 0x03: if note == 0 { type = .pitchBend }
                            case 0x0C: type = .setVolume; if vol == 0xFF { v1 = Float(info) / 64.0 }
                            case 0x0B: type = .patternJump; v1 = Float(info)
                            case 0x0D: type = .patternBreak; v1 = Float(info)
                            default: break
                            }
                        }
                        if ch < kMaxChannels {
                            rowMap[absRow * kMaxChannels + ch] = TrackerEvent(type: type, channel: UInt8(ch), instrument: ins, value1: v1, value2: vol <= 64 ? Float(vol)/64.0 : -1.0, effectCommand: cmd, effectParam: info)
                        }
                    }
                }
            }
            offset += (64 * numChn * 5)
        }

        // 2. Instrument Headers
        var currentSampleOffset = offset + (numInstru * 232)
        var currentBankOffset   = 0

        for i in 1...max(1, numInstru) {
            guard i <= numInstru, offset + 232 <= data.count else { break }
            var inst = Instrument()
            let nameStr = String(data: data[offset..<offset+32], encoding: .ascii)?.replacingOccurrences(of: "\0", with: "") ?? "Inst \(i)"
            inst.setName(nameStr)

            let sLen       = Int(data[offset+32]) | (Int(data[offset+33]) << 8) | (Int(data[offset+34]) << 16) | (Int(data[offset+35]) << 24)
            let rawFine44  = offset + 44 < data.count ? Int(data[offset + 44] & 0x0F) : 0
            let rawFine24  = offset + 24 < data.count ? Int(data[offset + 24] & 0x0F) : 0
            let rawFine    = rawFine44 != 0 ? rawFine44 : rawFine24
            let finetune   = Int8(rawFine > 7 ? rawFine - 16 : rawFine)
            let isStereo   = offset + 46 < data.count ? (data[offset + 46] != 0) : false

            if sLen > 0 {
                var region = SampleRegion(offset: currentBankOffset, length: sLen, isStereo: isStereo)
                region.finetune = finetune
                let loopStart  = Int(data[offset+36]) | (Int(data[offset+37]) << 8) | (Int(data[offset+38]) << 16) | (Int(data[offset+39]) << 24)
                let loopLen    = Int(data[offset+40]) | (Int(data[offset+41]) << 8) | (Int(data[offset+42]) << 16) | (Int(data[offset+43]) << 24)
                let loopTypeRaw = offset + 47 < data.count ? data[offset + 47] : 0
                if loopLen > 2 {
                    region.loopStart  = loopStart
                    region.loopLength = loopLen
                    region.loopType   = loopTypeRaw == 2 ? .pingPong : .classic
                }
                inst.addRegion(region)

                let sampleCount = isStereo ? sLen * 2 : sLen
                let byteCount   = sampleCount * 2
                if let bank = sampleBank, currentSampleOffset + byteCount <= data.count {
                    let rawSamples = data.subdata(in: currentSampleOffset..<currentSampleOffset + byteCount)
                    rawSamples.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                        let int16Ptr = bytes.baseAddress!.assumingMemoryBound(to: Int16.self)
                        let floatPtr = bank.samplePointer.advanced(by: currentBankOffset)
                        var scale = Float(1.0 / 32767.0)
                        vDSP_vflt16(int16Ptr, 1, floatPtr, 1, vDSP_Length(sampleCount))
                        vDSP_vsmul(floatPtr, 1, &scale, floatPtr, 1, vDSP_Length(sampleCount))
                    }
                    currentSampleOffset += byteCount
                }
                currentBankOffset += sampleCount
            }
            instMap[i] = inst
            offset += 232
        }

        // 3. AUv3 Plugin State Trailer ("TOOO" chunk)
        var pluginStates: [String: Data] = [:]
        if currentSampleOffset + 8 <= data.count {
            let tag = String(data: data[currentSampleOffset..<currentSampleOffset + 4], encoding: .ascii)
            if tag == "TOOO" {
                let chunkLen = Int(data[currentSampleOffset+4])
                             | (Int(data[currentSampleOffset+5]) << 8)
                             | (Int(data[currentSampleOffset+6]) << 16)
                             | (Int(data[currentSampleOffset+7]) << 24)
                let jsonStart = currentSampleOffset + 8
                if jsonStart + chunkLen <= data.count,
                   let decoded = try? JSONDecoder().decode([String: String].self, from: data[jsonStart..<jsonStart + chunkLen]) {
                    pluginStates = decoded.compactMapValues { Data(base64Encoded: $0) }
                }
            }
        }
        return (rowMap, instMap, pluginStates)
    }

    // MARK: - ProTracker / FastTracker MOD Parser

    /// Convert a ProTracker period to the Amiga PAL hardware playback rate (samples/second).
    ///
    /// SynthVoice.step = amigaRate / outputSampleRate.  This produces the correct pitch because:
    ///   step × outputRate = amigaRate source-samples/sec
    ///   pitch = amigaRate / samplesPerCycle
    ///
    /// Storing the Amiga rate (not musical Hz) also keeps portamento math correct:
    ///   period = palClock / amigaRate   →   pitch slides via period increments work exactly.
    ///
    /// PAL Amiga clock = 7,093,789 / 2 = 3,546,894.6 Hz.
    private static let palClock: Double = 3_546_895.0

    private func periodToAmigaRate(_ period: Int) -> Float {
        guard period > 0 else { return 0 }
        return Float(MADParser.palClock / Double(period * 2))
    }

    private func isMODMarker(_ m: String) -> Bool {
        let known4 = ["M.K.", "M!K!", "FLT4", "FLT8", "8CHN", "6CHN", "4CHN", "2CHN"]
        if known4.contains(m) { return true }
        // "xxCH" and "xxCN" patterns (e.g. "10CH", "16CN")
        let s = m.unicodeScalars.map { $0.value }
        if s.count == 4 && (m.hasSuffix("CH") || m.hasSuffix("CN")) {
            return Int(m.prefix(2)) != nil || Int(m.prefix(1)) != nil
        }
        return false
    }

    private func modChannelCount(_ marker: String) -> Int {
        switch marker {
        case "M.K.", "M!K!", "FLT4", "4CHN": return 4
        case "6CHN": return 6
        case "FLT8", "8CHN": return 8
        case "2CHN": return 2
        default:
            if let n = Int(marker.prefix(2)), n > 0 { return n }
            if let n = Int(marker.prefix(1)), n > 0 { return n }
            return 4
        }
    }

    private func parseMOD(data: Data, marker: String, sampleBank: UnifiedSampleBank?) throws -> (UnsafeMutablePointer<TrackerEvent>, [Int: Instrument], [String: Data])? {
        let numChannels   = modChannelCount(marker)
        let numInstruments = 31   // ProTracker always has 31 instrument slots
        let songLength    = Int(data[950])  // number of positions in order table
        guard songLength > 0 else { return nil }

        // Find highest pattern index referenced in order table → numUniquePat
        var maxPatIdx = 0
        for i in 0..<128 { maxPatIdx = max(maxPatIdx, Int(data[952 + i])) }
        let numUniquePat = maxPatIdx + 1

        // Allocate event map
        let rowMap: UnsafeMutablePointer<TrackerEvent> = .allocate(capacity: kMaxChannels * 64 * 100)
        rowMap.initialize(repeating: .empty, count: kMaxChannels * 64 * 100)

        // Parse pattern data (starts at byte 1084)
        var patOffset = 1084
        for p in 0..<numUniquePat {
            let bytesPerPat = 64 * numChannels * 4
            guard patOffset + bytesPerPat <= data.count else { break }
            for row in 0..<64 {
                for ch in 0..<min(numChannels, kMaxChannels) {
                    let off = patOffset + (row * numChannels + ch) * 4
                    guard off + 3 < data.count else { continue }
                    let b0 = Int(data[off]), b1 = Int(data[off+1])
                    let b2 = Int(data[off+2]), b3 = Int(data[off+3])
                    let period     = (b0 & 0x0F) << 8 | b1
                    let instrument = ((b0 & 0xF0) >> 0) | ((b2 & 0xF0) >> 4)  // nibble merge
                    let effect     = UInt8(b2 & 0x0F)
                    let effectParam = UInt8(b3)

                    guard period > 0 || instrument > 0 || effect > 0 else { continue }

                    var type: TrackerEventType = .empty
                    var freq: Float = 0
                    var vol: Float  = -1.0

                    if period > 0 {
                        type = .noteOn
                        freq = periodToAmigaRate(period)
                    }
                    // Map common MOD effects
                    switch effect {
                    case 0x0C:  // Set volume
                        vol = Float(min(64, Int(effectParam))) / 64.0
                        if type == .empty { type = .setVolume }
                    case 0x0B:  // Pattern jump
                        type = .patternJump
                    case 0x0D:  // Pattern break
                        type = .patternBreak
                    default: break
                    }

                    let absRow = p * 64 + row
                    guard absRow < 64 * 100 else { continue }
                    rowMap[absRow * kMaxChannels + ch] = TrackerEvent(
                        type: type, channel: UInt8(ch),
                        instrument: UInt8(clamping: instrument),
                        value1: freq, value2: vol,
                        effectCommand: effect, effectParam: effectParam)
                }
            }
            patOffset += bytesPerPat
        }

        // Parse 31 instrument headers (offset 20, 30 bytes each)
        var instMap: [Int: Instrument] = [:]
        var sampleDataOffset = patOffset  // sample data follows all patterns
        var currentBankOffset = 0

        for i in 1...numInstruments {
            let hOff = 20 + (i - 1) * 30
            guard hOff + 30 <= data.count else { break }

            // Big-endian word length (in words; multiply by 2 for byte count)
            let wordLen = (Int(data[hOff + 22]) << 8) | Int(data[hOff + 23])
            let sLen    = wordLen * 2
            guard sLen > 0 else { continue }

            let name = String(data: data[hOff..<hOff+22], encoding: .ascii)?
                .replacingOccurrences(of: "\0", with: "")
                .trimmingCharacters(in: .whitespaces) ?? "Inst \(i)"

            let rawFine  = Int(data[hOff + 24] & 0x0F)
            let finetune = Int8(rawFine > 7 ? rawFine - 16 : rawFine)
            // let volume   = Int(data[hOff + 25])  // 0-64, ignored for now

            // Loop info (big-endian word offsets)
            let loopStartW = (Int(data[hOff + 26]) << 8) | Int(data[hOff + 27])
            let loopLenW   = (Int(data[hOff + 28]) << 8) | Int(data[hOff + 29])
            let loopStart  = loopStartW * 2
            let loopLen    = loopLenW * 2

            var inst = Instrument()
            inst.setName(name)
            var region = SampleRegion(offset: currentBankOffset, length: sLen, isStereo: false)
            region.finetune = finetune
            if loopLen > 2 {
                region.loopStart  = loopStart
                region.loopLength = loopLen
                region.loopType   = .classic
            }
            inst.addRegion(region)

            // Convert 8-bit signed PCM → float
            if let bank = sampleBank, sampleDataOffset + sLen <= data.count {
                let ptr = bank.samplePointer.advanced(by: currentBankOffset)
                for j in 0..<sLen {
                    ptr[j] = Float(Int8(bitPattern: data[sampleDataOffset + j])) / 128.0
                }
                sampleDataOffset += sLen
            }
            currentBankOffset += sLen
            instMap[i] = inst
        }

        return (rowMap, instMap, [:])
    }
}
