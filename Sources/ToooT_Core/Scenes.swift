/*
 *  PROJECT ToooT (ToooT_Core)
 *  Scene snapshots — "mixer states" that can be recalled as a group.
 *
 *  A Scene captures per-channel volumes/pans/mutes/solos/sends, bus volumes,
 *  master volume, sidechain config, and optional plugin-state blobs. Recall
 *  applies all of these atomically at a quantized transport boundary (or
 *  immediately if the user asks for it).
 *
 *  Scenes are persisted inside the `.mad` TOOO chunk alongside plugin states —
 *  keyed by "scene.<index>" so one project can carry up to 64 scenes.
 */

import Foundation

public struct SceneSnapshot: Codable, Sendable {
    public var name: String
    public var channelVolumes: [Float]
    public var channelPans:    [Float]
    public var channelMutes:   [Int32]
    public var channelSolos:   [Int32]
    /// Flat row-major: [channel * numBuses + bus].
    public var sendAmounts:    [Float]
    public var busVolumes:     [Float]
    public var masterVolume:   Float
    public var bpm:            Int
    public var sidechainChannel: Int32
    public var sidechainAmount:  Float

    public init(name: String = "Scene",
                channelVolumes: [Float] = [], channelPans: [Float] = [],
                channelMutes: [Int32] = [], channelSolos: [Int32] = [],
                sendAmounts: [Float] = [], busVolumes: [Float] = [],
                masterVolume: Float = 1.0, bpm: Int = 125,
                sidechainChannel: Int32 = -1, sidechainAmount: Float = 0) {
        self.name            = name
        self.channelVolumes  = channelVolumes
        self.channelPans     = channelPans
        self.channelMutes    = channelMutes
        self.channelSolos    = channelSolos
        self.sendAmounts     = sendAmounts
        self.busVolumes      = busVolumes
        self.masterVolume    = masterVolume
        self.bpm             = bpm
        self.sidechainChannel = sidechainChannel
        self.sidechainAmount  = sidechainAmount
    }
}

/// Per-project scene registry. Bound to PlaybackState at runtime.
public final class SceneBank: @unchecked Sendable {
    public private(set) var scenes: [Int: SceneSnapshot] = [:]

    public init() {}

    public func store(_ scene: SceneSnapshot, at index: Int) {
        scenes[index] = scene
    }

    public func remove(at index: Int) {
        scenes.removeValue(forKey: index)
    }

    public func scene(at index: Int) -> SceneSnapshot? {
        scenes[index]
    }

    // MARK: - Serialization helpers (for .mad TOOO chunk)

    /// Encodes all stored scenes as a single JSON dictionary keyed by "scene.<index>".
    /// MADWriter picks this up as plugin-state-shaped data to embed in the trailer.
    public func exportAsPluginStateData() -> [String: Data] {
        var out: [String: Data] = [:]
        let enc = JSONEncoder()
        for (idx, scene) in scenes {
            if let data = try? enc.encode(scene) {
                out["scene.\(idx)"] = data
            }
        }
        return out
    }

    public func importFromPluginStateData(_ states: [String: Data]) {
        let dec = JSONDecoder()
        for (key, data) in states where key.hasPrefix("scene.") {
            let idxStr = String(key.dropFirst("scene.".count))
            guard let idx = Int(idxStr),
                  let scene = try? dec.decode(SceneSnapshot.self, from: data) else { continue }
            scenes[idx] = scene
        }
    }
}
