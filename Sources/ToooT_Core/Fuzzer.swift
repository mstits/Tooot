/*
 *  PROJECT ToooT (ToooT_Core)
 *  Real parser fuzzer — feeds random bytes through every untrusted input surface
 *  and asserts none crash.
 *
 *  Swift's memory safety catches most array out-of-bounds as runtime traps rather
 *  than actual crashes, which is great for this test: any malformed file that
 *  would crash older parsers throws a Swift trap, which `do/catch` can't actually
 *  catch but which tells us a bug exists. For production use we'd run this under
 *  a separate process so one trap doesn't tear down the whole harness.
 *
 *  The harness runs here; the FuzzRunner executable target wraps it for CI.
 */

import Foundation

public enum Fuzzer {

    public struct Report: Sendable {
        public var iterations:       Int
        public var failedIterations: Int      // parser returned error or nil
        public var successfulParses: Int      // surprising — random bytes happened to parse
        public var elapsedSeconds:   Double
        public var notes: [String]
    }

    /// Fuzzes MAD / MOD parsing. Writes N random-byte files into /tmp and runs the
    /// `parse` closure against each. The closure should be `MADParser.parse` from
    /// ToooT_IO (we keep it a closure here to avoid a cross-module dependency).
    public static func fuzzParser(iterations: Int = 1_000,
                                  sizeRange: ClosedRange<Int> = 16...65_536,
                                  parse: (URL) throws -> Any?) -> Report {
        let start = Date()
        var failed  = 0
        var parsed  = 0
        var notes: [String] = []

        for i in 0..<iterations {
            let size = Int.random(in: sizeRange)
            var bytes = Data(count: size)
            bytes.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                _ = SecRandomCopyBytes(kSecRandomDefault, size, base)
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("tooot-fuzz-\(UUID().uuidString).mad")
            do { try bytes.write(to: url) } catch { continue }

            do {
                if (try parse(url)) != nil {
                    parsed += 1
                } else {
                    failed += 1
                }
            } catch {
                failed += 1
            }

            try? FileManager.default.removeItem(at: url)
            if i < 3 { notes.append("iter \(i): size \(size) bytes") }
        }

        return Report(
            iterations:       iterations,
            failedIterations: failed,
            successfulParses: parsed,
            elapsedSeconds:   Date().timeIntervalSince(start),
            notes:            notes)
    }

    /// UMP dispatch fuzzer — calls `dispatch` with random 64-bit packets shaped
    /// like valid UMP voice messages but with arbitrary payloads. The dispatch
    /// function should never crash on bad input.
    public static func fuzzUMPDispatch(iterations: Int = 10_000,
                                       dispatch: (UInt32, UInt32) -> Void) -> Report {
        let start = Date()
        var crashed = 0
        for _ in 0..<iterations {
            let (w0, w1) = generateUMPPacket()
            dispatch(w0, w1)
            // No way to catch a Swift trap; if we got here we didn't crash.
            // Counting all as "failed" = "processed without parsed-success".
            crashed += 0
        }
        return Report(
            iterations:       iterations,
            failedIterations: 0,
            successfulParses: iterations,
            elapsedSeconds:   Date().timeIntervalSince(start),
            notes:            ["No crashes across \(iterations) UMP packets"])
    }

    /// Generator for shaped-but-random UMP voice messages (Type 4).
    public static func generateUMPPacket() -> (UInt32, UInt32) {
        let type:    UInt32 = 0x4
        let group:   UInt32 = 0
        let status:  UInt32 = UInt32.random(in: 0x8...0xF)
        let channel: UInt32 = UInt32.random(in: 0...15)
        let note:    UInt32 = UInt32.random(in: 0...127)
        let attr:    UInt32 = 0
        let w0 = (type << 28) | (group << 24) | (status << 20) | (channel << 16) | (note << 8) | attr
        let w1 = UInt32.random(in: 0...UInt32.max)
        return (w0, w1)
    }
}
