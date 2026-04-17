/*
 *  PROJECT ToooT — FuzzRunner
 *  Standalone fuzzer driver. Runs `Fuzzer.fuzzParser` against `MADParser` for N
 *  iterations and reports. Non-zero exit on any iteration count < requested.
 *
 *  Usage:  FuzzRunner [iterations=1000]
 *
 *  Intended for CI — keeps parsers honest about malformed input.
 */

import Foundation
import ToooT_Core
import ToooT_IO

let iterations: Int = CommandLine.arguments.count > 1
    ? Int(CommandLine.arguments[1]) ?? 1_000
    : 1_000

print("═══ FuzzRunner — \(iterations) iterations against MADParser ═══")

let report = Fuzzer.fuzzParser(iterations: iterations) { url in
    let parser = MADParser(sourceURL: url)
    return try parser.parse(sampleBank: nil)
}

print(String(format: "elapsed: %.2fs", report.elapsedSeconds))
print("failed (no parse):       \(report.failedIterations)")
print("unexpectedly parsed:     \(report.successfulParses)")
let total = report.failedIterations + report.successfulParses
print("total iterations:        \(total) / \(iterations)")
for n in report.notes { print("  · \(n)") }

if total < iterations {
    print("❌ FAIL: parser crashed \(iterations - total) times (Swift trap interrupted run)")
    exit(1)
}
print("✅ PASS: no crashes across \(iterations) iterations")
exit(0)
