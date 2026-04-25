/*
 *  PROJECT ToooT (ToooT_IO)
 *  Lightweight metadata extraction for `.mad` files.
 *
 *  Designed to be the data layer for two future macOS extensions:
 *
 *    1. Spotlight `.mdimporter` — reads title, instrument names, and counts
 *       so users can search for projects by name without opening the app.
 *    2. Quick Look `.appex`   — pairs with `MADThumbnail` to render a tiny
 *       preview tile of the pattern grid in Finder.
 *
 *  Both extensions are .appex / .mdimporter bundles produced by Xcode; SPM
 *  cannot package them directly. The data extraction here is pure Foundation
 *  + ToooT_Core, so it's trivial to drop into either extension target.
 */

import Foundation
import ToooT_Core

public struct MADMetadata: Sendable, Codable {
    public var title: String
    public var format: String          // "MADK" / "MADG" / "Tooo" / "MOD"
    public var patternCount: Int
    public var channelCount: Int
    public var instrumentCount: Int
    public var instrumentNames: [String]
    public var fileSizeBytes: Int

    public init(title: String, format: String, patternCount: Int, channelCount: Int,
                instrumentCount: Int, instrumentNames: [String], fileSizeBytes: Int) {
        self.title = title
        self.format = format
        self.patternCount = patternCount
        self.channelCount = channelCount
        self.instrumentCount = instrumentCount
        self.instrumentNames = instrumentNames
        self.fileSizeBytes = fileSizeBytes
    }
}

public enum MADMetadataReader {
    /// Reads just the header of a `.mad` (or classic .mod) file and returns the
    /// fields a Spotlight importer or Quick Look extension cares about. Parsing
    /// is bounded — no instrument samples are decoded — so this is fast enough
    /// to run on every file Finder shows.
    public static func read(url: URL) -> MADMetadata? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count > 4 else { return nil }
        let fileSize = data.count

        let sig4 = String(data: data[0..<4], encoding: .ascii) ?? ""
        if sig4 == "MADK" || sig4 == "MADG" || sig4 == "Tooo" {
            return readMAD(data: data, format: sig4, fileSize: fileSize)
        }

        // Classic ProTracker / FastTracker .mod magic at byte 1080.
        if data.count >= 1084 {
            let marker = String(data: data[1080..<1084], encoding: .ascii) ?? ""
            if isMODMarker(marker) {
                return readMOD(data: data, marker: marker, fileSize: fileSize)
            }
        }

        return nil
    }

    private static func readMAD(data: Data, format: String, fileSize: Int) -> MADMetadata {
        let titleEnd = min(36, data.count)
        let titleRaw = String(data: data[4..<titleEnd], encoding: .ascii) ?? ""
        let title = titleRaw
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Header layout (matches MADParser.parseMAD):
        //   sig(4) + title(32) + reserved(239) + (3) + (8) + (3) + (3) = 292
        // then numPat[292] / numChn[293] / _[294] / numInst[295]
        let metaOffset = 4 + 32 + 239 + 3 + 8 + 3 + 3
        let numPat   = data.count > metaOffset     ? Int(data[metaOffset])     : 0
        let numChn   = data.count > metaOffset + 1 ? Int(data[metaOffset + 1]) : 0
        let numInst  = data.count > metaOffset + 3 ? Int(data[metaOffset + 3]) : 0

        // Instrument headers begin after the order list (1000 bytes).
        // Each instrument header is 232 bytes; first 32 bytes are the ASCII name.
        let instStart = metaOffset + 5 + 999
        let patternBytes = numPat * 64 * numChn * 5
        let instSectionStart = instStart + patternBytes

        var names: [String] = []
        names.reserveCapacity(min(numInst, 64))
        for i in 0..<min(numInst, 256) {
            let off = instSectionStart + i * 232
            guard off + 32 <= data.count else { break }
            let raw = String(data: data[off..<off + 32], encoding: .ascii) ?? ""
            let name = raw
                .replacingOccurrences(of: "\0", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { names.append(name) }
        }

        return MADMetadata(
            title: title.isEmpty ? url(fromData: data) : title,
            format: format,
            patternCount: numPat,
            channelCount: numChn,
            instrumentCount: numInst,
            instrumentNames: names,
            fileSizeBytes: fileSize)
    }

    private static func readMOD(data: Data, marker: String, fileSize: Int) -> MADMetadata {
        let titleRaw = String(data: data[0..<min(20, data.count)], encoding: .ascii) ?? ""
        let title = titleRaw
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let songLength: Int = data.count > 950 ? Int(data[950]) : 0
        var maxPat = 0
        if data.count > 1080 {
            for i in 0..<128 where 952 + i < data.count {
                maxPat = max(maxPat, Int(data[952 + i]))
            }
        }

        // ProTracker has 31 instrument slots; each header is 30 bytes starting at byte 20.
        var names: [String] = []
        for i in 0..<31 {
            let off = 20 + i * 30
            guard off + 22 <= data.count else { break }
            let raw = String(data: data[off..<off + 22], encoding: .ascii) ?? ""
            let name = raw
                .replacingOccurrences(of: "\0", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { names.append(name) }
        }

        return MADMetadata(
            title: title.isEmpty ? "Untitled" : title,
            format: "MOD/" + marker,
            patternCount: maxPat + 1,
            channelCount: modChannelCount(marker),
            instrumentCount: 31,
            instrumentNames: names,
            fileSizeBytes: fileSize)
    }

    private static func url(fromData _: Data) -> String { "Untitled" }

    private static func isMODMarker(_ m: String) -> Bool {
        let known4 = ["M.K.", "M!K!", "FLT4", "FLT8", "8CHN", "6CHN", "4CHN", "2CHN"]
        if known4.contains(m) { return true }
        if m.count == 4 && (m.hasSuffix("CH") || m.hasSuffix("CN")) {
            return Int(m.prefix(2)) != nil || Int(m.prefix(1)) != nil
        }
        return false
    }

    private static func modChannelCount(_ marker: String) -> Int {
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
}
