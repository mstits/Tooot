/*
 *  NextGenTracker (LegacyTracker 2026)
 *  Copyright (c) 2026. All rights reserved.
 *  Low-level binary parsing engine.
 */

import Foundation

public struct BinaryReader {
    public enum ReaderError: Error, Equatable {
        case unexpectedEOF
        case invalidEncoding
    }

    public let data: Data
    public var offset: Int = 0

    public init(data: Data) { self.data = data }

    public mutating func readByte() -> UInt8 {
        guard offset < data.count else { return 0 }
        defer { offset += 1 }
        return data[offset]
    }

    /// Throws ReaderError.unexpectedEOF if the requested bytes are unavailable.
    /// Use `(try? reader.readString(length: n)) ?? ""` at call sites that tolerate EOF.
    public mutating func readString(length: Int) throws -> String {
        guard offset + length <= data.count else { throw ReaderError.unexpectedEOF }
        let sub = data[offset..<offset + length]
        offset += length
        guard let s = String(data: sub, encoding: .ascii) else { throw ReaderError.invalidEncoding }
        return s.replacingOccurrences(of: "\0", with: "")
    }
    
    public mutating func readInt32() -> Int32 {
        guard offset + 4 <= data.count else { return 0 }
        let val = data[offset..<offset+4].withUnsafeBytes { $0.load(as: Int32.self) }
        offset += 4
        return val
    }
    
    public mutating func readInt16() -> Int16 {
        guard offset + 2 <= data.count else { return 0 }
        let val = data[offset..<offset+2].withUnsafeBytes { $0.load(as: Int16.self) }
        offset += 2
        return val
    }
    
    public mutating func readFloat() -> Float {
        guard offset + 4 <= data.count else { return 0.0 }
        let val = data[offset..<offset+4].withUnsafeBytes { $0.load(as: Float.self) }
        offset += 4
        return val
    }
}
