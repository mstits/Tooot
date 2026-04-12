/*
 *  PROJECT ToooT (ToooT_Core)
 *  Offline render + VLC comparison test.
 *
 *  Run:   swift test --filter OfflineRenderTests
 *  Then:  python3 /tmp/compare_audio.py
 */

import XCTest
import Foundation
import Accelerate
@testable import ToooT_Core
@testable import ToooT_IO

final class OfflineRenderTests: XCTestCase {

    // ── Paths ────────────────────────────────────────────────────────────────
    private let modURL   = URL(fileURLWithPath: "/Users/stits/Downloads/_happy_wind_.mod")
    private let outWAV   = URL(fileURLWithPath: "/tmp/tooot_happy_wind.wav")
    private let vlcWAV   = URL(fileURLWithPath: "/tmp/ref_happy_wind.wav")
    private let pyScript = URL(fileURLWithPath: "/tmp/compare_audio.py")

    // ── Main test ────────────────────────────────────────────────────────────

    func testRenderMODToWAV() throws {
        guard FileManager.default.fileExists(atPath: modURL.path) else {
            throw XCTSkip("MOD file not found at \(modURL.path)")
        }

        // 1. Parse MOD
        let transpiler = FormatTranspiler(sourceURL: modURL)
        let events     = try transpiler.createSnapshot(from: modURL)
        let instruments = transpiler.parseInstruments(from: modURL)
        let (orderList, songLength) = transpiler.parseMetadata(from: modURL)

        // 2. Load samples into a standalone bank
        let bank = UnifiedSampleBank(capacity: 32 * 262144)   // 32 instrument slots
        try transpiler.loadSamples(from: modURL, intoBank: bank)

        // 3. Build instrument slab (256-entry array of Instrument)
        let instSlab = UnsafeMutablePointer<Instrument>.allocate(capacity: 256)
        instSlab.initialize(repeating: Instrument(), count: 256)
        defer { instSlab.deallocate() }
        for (id, inst) in instruments where id < 256 { instSlab[id] = inst }

        // 4. Envelope enable flags (all off for plain MOD)
        let envFlags = UnsafeMutablePointer<Int32>.allocate(capacity: 256)
        envFlags.initialize(repeating: 0, count: 256)
        defer { envFlags.deallocate() }

        // 5. Build SongSnapshot
        let eventsPtr = UnsafeMutablePointer<TrackerEvent>.allocate(capacity: kMaxChannels * 64 * 100)
        eventsPtr.initialize(repeating: .empty, count: kMaxChannels * 64 * 100)
        defer { eventsPtr.deallocate() }
        events.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            memcpy(eventsPtr, base, src.count * MemoryLayout<TrackerEvent>.size)
        }
        let snap = SongSnapshot(
            events:      eventsPtr,
            instruments: instSlab,
            orderList:   orderList,
            songLength:  songLength,
            volEnv:      envFlags,
            panEnv:      envFlags,
            pitchEnv:    envFlags
        )

        // 6. Build render infrastructure
        let res      = RenderResources(maxFrames: 4096)
        let statePtr = UnsafeMutablePointer<EngineSharedState>.allocate(capacity: 1)
        statePtr.initialize(to: EngineSharedState())
        defer { statePtr.deallocate() }

        // Amiga cross-channel panning: L R R L
        res.channelPans[0] = 0.0
        res.channelPans[1] = 1.0
        res.channelPans[2] = 1.0
        res.channelPans[3] = 0.0

        let evtBuf   = AtomicRingBuffer<TrackerEvent>(capacity: 16)
        let node     = AudioRenderNode(resources: res, statePtr: statePtr, bank: bank, eventBuffer: evtBuf)

        // 7. Configure playback state
        statePtr.pointee.isPlaying    = 1
        statePtr.pointee.bpm          = 125
        statePtr.pointee.ticksPerRow  = 6
        statePtr.pointee.masterVolume = 0.8

        // 8. Allocate output buffers — 3 min @ 44100 max
        let maxFrames = 44100 * 180
        let bufL = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
        let bufR = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
        bufL.initialize(repeating: 0, count: maxFrames)
        bufR.initialize(repeating: 0, count: maxFrames)
        defer { bufL.deallocate(); bufR.deallocate() }

        // 9. Render
        let rendered = node.renderOffline(frames: maxFrames, snap: snap, state: statePtr,
                                          bufferL: bufL, bufferR: bufR)
        XCTAssertGreaterThan(rendered, 0, "renderOffline produced no audio")

        // 10. Write WAV (float32 stereo)
        writeWAV(path: outWAV.path, bufL: bufL, bufR: bufR, frames: rendered, sampleRate: 44100)
        print("✅ Wrote \(rendered) frames (\(String(format: "%.2f", Double(rendered)/44100.0))s) → \(outWAV.path)")

        // 11. Emit VLC render command + Python comparison script
        emitVLCCommand()
        emitPythonScript(rendered: rendered)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outWAV.path),
                      "WAV not written to \(outWAV.path)")
    }

    // ── WAV writer (IEEE float32, stereo, 44100 Hz) ──────────────────────────

    private func writeWAV(path: String, bufL: UnsafePointer<Float>, bufR: UnsafePointer<Float>,
                          frames: Int, sampleRate: Int) {
        let channels   = 2
        let bitsPerSample = 32
        let byteRate   = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataBytes  = frames * channels * bitsPerSample / 8
        let fileSize   = 36 + dataBytes

        var header = Data()
        func u32le(_ v: Int) { var x = UInt32(v).littleEndian; header.append(contentsOf: withUnsafeBytes(of: &x) { Array($0) }) }
        func u16le(_ v: Int) { var x = UInt16(v).littleEndian; header.append(contentsOf: withUnsafeBytes(of: &x) { Array($0) }) }

        header.append(contentsOf: "RIFF".utf8)
        u32le(fileSize)
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        u32le(16)               // chunk size
        u16le(3)                // PCM IEEE float
        u16le(channels)
        u32le(sampleRate)
        u32le(byteRate)
        u16le(blockAlign)
        u16le(bitsPerSample)
        header.append(contentsOf: "data".utf8)
        u32le(dataBytes)

        var fileData = header
        // Interleave L/R
        for i in 0..<frames {
            var l = bufL[i], r = bufR[i]
            fileData.append(contentsOf: withUnsafeBytes(of: &l) { Array($0) })
            fileData.append(contentsOf: withUnsafeBytes(of: &r) { Array($0) })
        }
        try? fileData.write(to: URL(fileURLWithPath: path))
    }

    // ── Helper: print VLC headless render command ────────────────────────────

    private func emitVLCCommand() {
        print("""

        ── VLC reference render ──────────────────────────────────────────
        Run this command to produce the VLC reference WAV, then run the
        Python comparison script:

          /Applications/VLC.app/Contents/MacOS/VLC --intf dummy --play-and-exit \\
            --no-video --audio-filter=normvol \\
            --sout '#transcode{acodec=s16l,channels=2,samplerate=44100}:std{access=file,mux=wav,dst=\(vlcWAV.path)}' \\
            "\(modURL.path)"

        ─────────────────────────────────────────────────────────────────
        """)
    }

    // ── Helper: write Python comparison script ───────────────────────────────

    private func emitPythonScript(rendered: Int) {
        let script = """
        #!/usr/bin/env python3
        \"\"\"
        Audio comparison: ToooT engine vs VLC reference for 4thtrain.mod
        Usage: python3 \(pyScript.path)
        \"\"\"
        import sys, struct, math
        import numpy as np

        def read_wav(path):
            import wave
            try:
                with wave.open(path, 'rb') as w:
                    n  = w.getnframes()
                    ch = w.getnchannels()
                    sw = w.getsampwidth()
                    raw = w.readframes(n)
                if sw == 4:  # float32
                    data = np.frombuffer(raw, dtype='<f4').reshape(-1, ch)
                elif sw == 2:
                    data = np.frombuffer(raw, dtype='<i2').reshape(-1, ch).astype(np.float32) / 32768.0
                else:
                    sys.exit(f"Unsupported sample width: {sw}")
                return data[:, 0], data[:, 1], w.getframerate()
            except Exception as e:
                sys.exit(f"Cannot read {path}: {e}")

        tooot_L, tooot_R, sr_p = read_wav("\(outWAV.path)")
        vlc_L,  vlc_R,  sr_v = read_wav("\(vlcWAV.path)")

        print(f"ToooT  : {len(tooot_L)/sr_p:.2f}s  sr={sr_p}")
        print(f"VLC   : {len(vlc_L)/sr_v:.2f}s  sr={sr_v}")

        # Align lengths
        n = min(len(tooot_L), len(vlc_L), 44100*30)  # compare first 30s
        pL, pR = tooot_L[:n], tooot_R[:n]
        vL, vR = vlc_L[:n],  vlc_R[:n]

        def stats(sig, label):
            print(f"  {label}  peak={np.max(np.abs(sig)):.4f}  rms={np.sqrt(np.mean(sig**2)):.4f}")

        print("\\n── ToooT ──")
        stats(pL, "L"); stats(pR, "R")
        print("── VLC  ──")
        stats(vL, "L"); stats(vR, "R")

        # Normalise both to peak 1.0 before comparing pitch/content
        norm = lambda s: s / (np.max(np.abs(s)) + 1e-9)
        pLn, vLn = norm(pL), norm(vL)
        pRn, vRn = norm(pR), norm(vR)

        corr_L = np.corrcoef(pLn, vLn)[0, 1]
        corr_R = np.corrcoef(pRn, vRn)[0, 1]
        print(f"\\n── Waveform correlation (after normalisation) ──")
        print(f"  L: {corr_L:.4f}  R: {corr_R:.4f}")
        print(f"  (1.0 = perfect match, <0.5 = significant divergence)")

        # Spectral centroid comparison (first 5s)
        def spectral_centroid(sig, sr=44100, n_fft=4096):
            win = sig[:n_fft]
            mag = np.abs(np.fft.rfft(win * np.hanning(n_fft)))
            freqs = np.fft.rfftfreq(n_fft, 1/sr)
            return float(np.sum(freqs * mag) / (np.sum(mag) + 1e-9))

        print(f"\\n── Spectral centroid (first 4096 samples) ──")
        print(f"  ToooT L: {spectral_centroid(pL):.1f} Hz")
        print(f"  VLC  L: {spectral_centroid(vL):.1f} Hz")

        # Row-by-row RMS (every 44100//6//6 samples = ~1 row at 125BPM/6tpr)
        row_samples = int(sr_p * 2.5 / 125 * 6)  # samples per row
        rows_to_check = min(32, n // row_samples)
        print(f"\\n── Per-row RMS (first {rows_to_check} rows, {row_samples} samp/row) ──")
        print(f"  {'Row':>3}  {'ToooT L':>8}  {'VLC L':>8}  {'ratio':>6}")
        for r in range(rows_to_check):
            s, e = r*row_samples, (r+1)*row_samples
            pr = math.sqrt(np.mean(pL[s:e]**2) + 1e-12)
            vr = math.sqrt(np.mean(vL[s:e]**2) + 1e-12)
            ratio = pr / vr
            flag = " ◀ MISMATCH" if abs(ratio - 1.0) > 0.4 else ""
            print(f"  {r:>3}  {pr:>8.5f}  {vr:>8.5f}  {ratio:>6.3f}{flag}")
        """

        try? script.write(to: pyScript, atomically: true, encoding: .utf8)
        print("📝 Python comparison script written to \(pyScript.path)")
        print("   Run it after the VLC render completes.")
    }
}
