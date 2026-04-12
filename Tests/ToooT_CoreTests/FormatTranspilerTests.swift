import XCTest
@testable import ToooT_Core
@testable import ToooT_IO

final class FormatTranspilerTests: XCTestCase {
    
    func testBinaryReaderSafety() {
        // Create 2 bytes of data
        let unsafeData = Data([0x4D, 0x2E]) // "M."
        var reader = BinaryReader(data: unsafeData)
        
        // Ensure reading 4 bytes throws unexpectedEOF securely instead of segfaulting
        XCTAssertThrowsError(try reader.readString(length: 4)) { error in
            XCTAssertEqual(error as? BinaryReader.ReaderError, BinaryReader.ReaderError.unexpectedEOF)
        }
    }
    
    func testSnapshotMapping() throws {
        // Mock a massive block satisfying protracker offsets
        var mockData = Data(count: 1084)
        // Set M.K. at 1080
        mockData[1080] = 0x4D // M
        mockData[1081] = 0x2E // .
        mockData[1082] = 0x4B // K
        mockData[1083] = 0x2E // .
        
        // Add a note in the first pattern (Pattern 0)
        // patternStart is 1084. Row 0, Channel 1 starts at 1084 + 0*16 + 1*4 = 1088
        mockData.append(Data(count: 1024)) // Pattern 0
        mockData[1088] = 0x00 
        mockData[1089] = 0x71 // Period 0x071 (atoootx. C-2)
        mockData[1090] = 0x10 
        
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("mock.mod")
        try mockData.write(to: tempURL)
        
        let transpiler = FormatTranspiler(sourceURL: tempURL)
        let rowMap = try transpiler.createSnapshot(from: tempURL)
        
        // Row 0, Channel 1 should have the noteOn event
        // FormatTranspiler uses rowMap[absRow * 256 + channel]
        let event = rowMap[0 * 256 + 1]
        XCTAssertEqual(event.type, .noteOn)
        XCTAssertEqual(event.instrument, 1)
    }
}
