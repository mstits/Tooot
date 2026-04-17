/*
 *  PROJECT ToooT (ToooT_UI)
 *  Text-to-speech via AVSpeechSynthesizer — the native macOS TTS engine (same
 *  one `say` uses from the CLI). Free, shipped with the OS, no licensing.
 *
 *  Use cases:
 *    • JIT shell: `say "kick on one"` for accessibility or quick voice notes
 *    • Scripts: generate a custom vocal sample directly into an instrument slot
 *    • Live: announce scene names or cue markers over monitor bus
 *
 *  For the "TALK from CLI" requirement: `ToooTTalk.speak(_:)` is callable from
 *  anywhere (including the UATRunner). The macOS `say` binary can also be
 *  invoked through Process() for rendering TTS to an AIFF/WAV file — we expose
 *  that path too so users can bake speech into the sample bank.
 */

import Foundation
import AVFoundation

@MainActor
public final class ToooTTalk {
    public static let shared = ToooTTalk()
    private let synth = AVSpeechSynthesizer()

    public init() {}

    /// Speaks a string through the system output. Non-blocking.
    /// `voice` is a BCP-47 tag like "en-US" or "en-GB" — defaults to system.
    /// `rate` / `pitch` / `volume` are 0…1, 0.5…2, 0…1 respectively.
    public func speak(_ text: String,
                      voice: String = "en-US",
                      rate:  Float = 0.5,
                      pitch: Float = 1.0,
                      volume: Float = 1.0) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice  = AVSpeechSynthesisVoice(language: voice)
        utterance.rate   = max(AVSpeechUtteranceMinimumSpeechRate,
                               min(AVSpeechUtteranceMaximumSpeechRate, rate))
        utterance.pitchMultiplier = pitch
        utterance.volume          = volume
        synth.speak(utterance)
    }

    public func stop() {
        synth.stopSpeaking(at: .immediate)
    }

    /// Renders speech to a WAV file by shelling out to macOS `say`. Synchronous —
    /// call from a background Task. Returns the output URL or nil on failure.
    ///
    /// Useful in scripts / JIT: `talk-render "announcement" → sample slot`.
    public static func renderToFile(text: String,
                                    voice: String = "Samantha",
                                    at outputURL: URL) -> URL? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        task.arguments = [
            "-v", voice,
            "-o", outputURL.path,
            "--data-format=LEF32@44100",
            "--file-format=WAVE",
            text
        ]
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 { return outputURL }
        } catch { return nil }
        return nil
    }

    /// Returns available voice names. Runs `say -v ?` and parses the output.
    public static func availableVoices() -> [String] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        task.arguments = ["-v", "?"]
        let pipe = Pipe(); task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let str = String(data: data, encoding: .utf8) ?? ""
            return str.split(separator: "\n")
                       .compactMap { $0.split(separator: " ").first.map(String.init) }
                       .filter { !$0.isEmpty }
        } catch { return [] }
    }
}
