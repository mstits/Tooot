/*
 *  PROJECT ToooT (ToooT_UI)
 *  Copyright (c) 2026 Apple Core Audio / Pro Apps Division.
 *  Document Architecture for Native macOS 16 Integration.
 */

import SwiftUI
import UniformTypeIdentifiers
import ToooT_Core
import ToooT_IO

extension UTType {
    public static let mod = UTType(importedAs: "public.mod-audio")
    public static let madk = UTType(importedAs: "com.apple.legacytracker.madk")
    public static let madh = UTType(importedAs: "com.apple.legacytracker.madh")
}

public final class TrackerDocument: ReferenceFileDocument, @unchecked Sendable {
    public var sequencerData = SequencerData()
    public var instruments: [Int: Instrument] = [:]
    public var fileURL: URL?
    
    public static var readableContentTypes: [UTType] { [.mod, .madk, .madh, .data, .audio] }
    
    public init() {
        // Empty default document
    }
    
    public init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents {
            let transpiler = FormatTranspiler()
            // We write to a temporary file natively as our transpiler logic uses URLs.
            // In a production 1:1, we would parse the Data directly.
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mod")
            try data.write(to: tempURL)
            self.fileURL = tempURL
            
            let eventsArr = try transpiler.createSnapshot(from: tempURL)
            for i in 0..<min(eventsArr.count, kMaxChannels * 64 * 100) {
                self.sequencerData.events[i] = eventsArr[i]
            }
            self.instruments = transpiler.parseInstruments(from: tempURL)
        } else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
    
    public func snapshot(contentType: UTType) throws -> UnsafeMutablePointer<TrackerEvent> {
        return sequencerData.events
    }
    
    public func fileWrapper(snapshot: UnsafeMutablePointer<TrackerEvent>, configuration: WriteConfiguration) throws -> FileWrapper {
        throw CocoaError(.fileWriteUnsupportedScheme) // Read-only for MVP
    }
}
