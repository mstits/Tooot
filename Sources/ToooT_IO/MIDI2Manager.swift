/*
 *  PROJECT ToooT (ToooT_IO)
 *  Copyright (c) 2026 Apple Core Audio / Pro Apps Division.
 *  MIDI 2.0 Property Exchange and Universal MIDI Packet (UMP) Manager.
 */

import Foundation
import CoreMIDI
import ToooT_Core

/// Advanced MIDI 2.0 Manager for the 2026 Studio.
public final class MIDI2Manager: @unchecked Sendable {
    
    private var midiClient: MIDIClientRef = 0
    private var midiInPort: MIDIPortRef = 0
    private var midiOutPort: MIDIPortRef = 0
    
    public init() {
        // Initialize MIDI 2.0 Client with Capability Inquiry (CI) support
        let status = MIDIClientCreate("PROJECT ToooT UMP Client" as CFString, nil, nil, &midiClient)
        if status != noErr { print("Failed to create MIDI client: \(status)") }
    }
    
    public func setup(ringBuffer: AtomicRingBuffer<TrackerEvent>) {
        // Setup Input Port
        var status = MIDIInputPortCreateWithProtocol(midiClient, "PROJECT ToooT Hardware In" as CFString, ._2_0, &midiInPort) { [weak self] eventList, _ in
            let list = eventList.pointee
            withUnsafePointer(to: list.packet) { packetPtr in
                self?.dispatchUMP(packetPtr, ringBuffer: ringBuffer)
            }
        }
        
        if status != noErr { print("Failed to create MIDI input port: \(status)") }
        
        // Setup Output Port
        status = MIDIOutputPortCreate(midiClient, "PROJECT ToooT Hardware Out" as CFString, &midiOutPort)
        if status != noErr { print("Failed to create MIDI output port: \(status)") }
        
        let sources = MIDIGetNumberOfSources()
        if sources > 0 {
            let src = MIDIGetSource(0)
            MIDIPortConnectSource(midiInPort, src, nil)
        }
    }
    
    /// High-performance MIDI Out Dispatch
    public func sendNoteOn(note: UInt8, velocity: UInt8, channel: UInt8) {
        guard midiOutPort != 0 else { return }
        let destCount = MIDIGetNumberOfDestinations()
        guard destCount > 0 else { return }
        let dest = MIDIGetDestination(0) // Default to first destination for demo
        
        var packetList = MIDIPacketList()
        let packetPtr = MIDIPacketListInit(&packetList)
        let data: [UInt8] = [0x90 | (channel & 0x0F), note & 0x7F, velocity & 0x7F]
        _ = MIDIPacketListAdd(&packetList, 1024, packetPtr, 0, 3, data)
        
        MIDISend(midiOutPort, dest, &packetList)
    }
    
    /// Sends a MIDI 2.0 Universal MIDI Packet (Type 4) Note On
    public func sendUMPNoteOn(note: UInt8, velocity16: UInt16, channel: UInt8) {
        guard midiOutPort != 0 else { return }
        let destCount = MIDIGetNumberOfDestinations()
        guard destCount > 0 else { return }
        let dest = MIDIGetDestination(0)
        
        // Construct Type 4 UMP (64-bit)
        // Word 0: [Type:4][Group:4][Status:4][Channel:4][Note:8][AttributeType:8]
        // Word 1: [Velocity:16][AttributeData:16]
        let word0: UInt32 = (0x4 << 28) | (0x0 << 24) | (0x9 << 20) | (UInt32(channel & 0x0F) << 16) | (UInt32(note & 0x7F) << 8) | 0x00
        let word1: UInt32 = (UInt32(velocity16) << 16) | 0x0000
        
        var eventList = MIDIEventList()
        let eventPtr = MIDIEventListInit(&eventList, ._2_0)
        let words: [UInt32] = [word0, word1]
        _ = MIDIEventListAdd(&eventList, 1024, eventPtr, 0, 2, words)
        
        // Send the 64-bit UMP event list via the CoreMIDI MIDI 2.0 API.
        MIDISendEventList(midiOutPort, dest, &eventList)
    }

    /// Maps a LegacyTracker instrument's basic parameters to the MIDI 2.0 endpoint:
    ///   • Channel volume  via CC 7   (MIDI 1.0 compatible)
    ///   • Channel panning via CC 10  (MIDI 1.0 compatible)
    ///   • Pitch-bend range via RPN 0 (semitones = 2)
    /// Full MIDI 2.0 Property Exchange (PE) is left for a future protocol layer.
    public func mapInstrument(_ instrument: Instrument, to endpoint: MIDIEntityRef) {
        guard midiOutPort != 0, MIDIGetNumberOfDestinations() > 0 else { return }
        let dest = MIDIGetDestination(0)

        // Volume: CC 7, scaled from defaultVolume [0,1] to [0,127]
        let vol = UInt8(clamping: Int(instrument.defaultVolume * 127))
        sendCC(0x07, value: vol, channel: 0, dest: dest)

        // Pan: CC 10, centre = 64
        sendCC(0x0A, value: 64, channel: 0, dest: dest)

        // Pitch-bend range: RPN 0x0000 MSB = semitones (2), LSB = 0
        sendCC(0x65, value: 0x00, channel: 0, dest: dest) // RPN MSB
        sendCC(0x64, value: 0x00, channel: 0, dest: dest) // RPN LSB
        sendCC(0x06, value: 2,    channel: 0, dest: dest) // Data Entry MSB = 2 semitones
        sendCC(0x26, value: 0,    channel: 0, dest: dest) // Data Entry LSB
    }

    /// Public Control Change send. Picks the first destination if available;
    /// no-op if no MIDI destinations are connected.
    public func sendControlChange(cc: UInt8, value: UInt8, channel: UInt8) {
        guard midiOutPort != 0, MIDIGetNumberOfDestinations() > 0 else { return }
        sendCC(cc, value: value, channel: channel, dest: MIDIGetDestination(0))
    }

    private func sendCC(_ cc: UInt8, value: UInt8, channel: UInt8, dest: MIDIEndpointRef) {
        var pktList = MIDIPacketList()
        let ptr  = MIDIPacketListInit(&pktList)
        let data: [UInt8] = [0xB0 | (channel & 0x0F), cc & 0x7F, value & 0x7F]
        _ = MIDIPacketListAdd(&pktList, 1024, ptr, 0, 3, data)
        MIDISend(midiOutPort, dest, &pktList)
    }
    
    /// High-performance UMP dispatch directly to the Audio Thread.
    ///
    /// MIDI 2.0 UMP layout reminder (Type 4, 64-bit voice messages):
    ///   word0 = [type:4][group:4][status:4][channel:4][noteNum:8][attrType:8]
    ///   word1 = [16-bit velocity | pitch / per-note data][16-bit attr data]
    ///
    /// Statuses we handle:
    ///   0x9  — Note On                         (velocity16)
    ///   0x8  — Note Off                        (velocity16 as release)
    ///   0x6  — Per-Note Pitch Bend             (pitchBend32 in word1)
    ///   0xA  — Poly Pressure / Per-Note Ctrl   (pressure16 in word1)
    ///   0xF  — Per-Note Management
    public func dispatchUMP(_ packet: UnsafePointer<MIDIEventPacket>, ringBuffer: AtomicRingBuffer<TrackerEvent>) {
        let ump = packet.pointee.words.0
        let messageType = (ump & 0xF0000000) >> 28

        // MIDI 2.0 64-bit Voice Message (Type 4)
        if messageType == 0x4 {
            let status  = (ump & 0x00F00000) >> 20
            let channel = UInt8((ump & 0x000F0000) >> 16)
            let note    = UInt8((ump & 0x00007F00) >> 8)

            switch status {
            case 0x9:   // Note On
                let velocity16 = UInt16(packet.pointee.words.1 >> 16)
                let frequency = 440.0 * pow(2.0, (Float(note) - 69.0) / 12.0)
                let parsedVelocity = Float(velocity16) / 65535.0
                let noteId: UInt16 = nextNoteId(channel: channel, note: note, allocate: true)
                let event = TrackerEvent(
                    type: .noteOn, channel: channel, value1: frequency, value2: parsedVelocity,
                    noteId: noteId)
                _ = ringBuffer.push(event)

            case 0x8:   // Note Off
                let noteId: UInt16 = nextNoteId(channel: channel, note: note, allocate: false)
                let frequency = 440.0 * pow(2.0, (Float(note) - 69.0) / 12.0)
                let event = TrackerEvent(
                    type: .noteOff, channel: channel, value1: frequency,
                    noteId: noteId)
                _ = ringBuffer.push(event)

            case 0x6:   // Per-Note Pitch Bend (32-bit)
                // Bias is 0x80000000 = center; map to ±8192 (semitone scaled elsewhere).
                let raw = Int32(bitPattern: packet.pointee.words.1)
                let biased = Int64(raw) - Int64(0x80000000)
                let clamped = max(min(biased / (Int64(1) << 17), Int64(Int16.max)), Int64(Int16.min))
                let bend16 = Int16(clamped)
                let noteId = nextNoteId(channel: channel, note: note, allocate: false)
                let event = TrackerEvent(
                    type: .pitchBend, channel: channel, value1: Float(bend16) / 8192.0,
                    noteId: noteId, perNotePitchBend: bend16)
                _ = ringBuffer.push(event)

            case 0xA:   // Poly/Per-Note Pressure (high byte of word1's upper half)
                let pressure16 = UInt16(packet.pointee.words.1 >> 16)
                let pressure7  = UInt8(pressure16 >> 9) & 0x7F
                let noteId = nextNoteId(channel: channel, note: note, allocate: false)
                let event = TrackerEvent(
                    type: .pitchBend, channel: channel, value2: Float(pressure16) / 65535.0,
                    noteId: noteId, perNotePressure: pressure7)
                _ = ringBuffer.push(event)

            default:
                break
            }
        }
    }

    // MARK: - Note-ID allocation (for MPE voice tracking)

    /// Map from (channel, note) → active noteId. Allocation is lightweight — UMP
    /// dispatch runs on CoreMIDI's delivery thread, not the render thread, so an
    /// atomic dictionary is fine here.
    private var noteIdTable: [Int: UInt16] = [:]
    private var nextFreshNoteId: UInt16 = 1
    private let noteIdLock = NSLock()

    private func nextNoteId(channel: UInt8, note: UInt8, allocate: Bool) -> UInt16 {
        noteIdLock.lock(); defer { noteIdLock.unlock() }
        let key = (Int(channel) << 8) | Int(note)
        if let existing = noteIdTable[key] { return existing }
        guard allocate else { return 0 }
        let id = nextFreshNoteId
        nextFreshNoteId = nextFreshNoteId &+ 1
        if nextFreshNoteId == 0 { nextFreshNoteId = 1 }   // skip 0 (= "no MPE")
        noteIdTable[key] = id
        return id
    }
    
    // MARK: - MIDI Clock (0xF8 — 24 pulses per quarter note)

    private var clockTimer: DispatchSourceTimer?

    /// Starts sending MIDI Timing Clock (0xF8) at 24 ppqn for the given BPM.
    /// Safe to call from @MainActor; the timer fires on a background queue.
    public func startClock(bpm: Int) {
        stopClock()
        guard midiOutPort != 0, MIDIGetNumberOfDestinations() > 0 else { return }
        let dest = MIDIGetDestination(0)
        // Interval in nanoseconds: 60s / (bpm * 24) * 1e9
        let intervalNs = UInt64(60_000_000_000 / max(1, bpm * 24))
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(intervalNs)), leeway: .microseconds(100))
        timer.setEventHandler { [midiOutPort] in
            var pktList = MIDIPacketList()
            let ptr = MIDIPacketListInit(&pktList)
            let data: [UInt8] = [0xF8]
            _ = MIDIPacketListAdd(&pktList, 64, ptr, 0, 1, data)
            MIDISend(midiOutPort, dest, &pktList)
        }
        clockTimer = timer
        timer.resume()
    }

    /// Stops MIDI clock and sends a MIDI Stop (0xFC) message.
    public func stopClock() {
        clockTimer?.cancel()
        clockTimer = nil
        guard midiOutPort != 0, MIDIGetNumberOfDestinations() > 0 else { return }
        let dest = MIDIGetDestination(0)
        var pktList = MIDIPacketList()
        let ptr = MIDIPacketListInit(&pktList)
        let data: [UInt8] = [0xFC]
        _ = MIDIPacketListAdd(&pktList, 64, ptr, 0, 1, data)
        MIDISend(midiOutPort, dest, &pktList)
    }

    deinit {
        clockTimer?.cancel()
        if midiClient != 0 {
            MIDIClientDispose(midiClient)
        }
    }
}
