/*
 *  PROJECT ToooT (ToooT_Core)
 *  Copyright (c) 2026 Apple Core Audio / Pro Apps Division.
 *
 *  AtomicRingBuffer — Swift 6 strict-concurrency SPSC ring buffer.
 *
 *  Replaces AudioRingBuffer.swift, eliminating:
 *    • OSMemoryBarrier() (deprecated macOS 13, removed macOS 26)
 *    • ManagedBuffer ARC retain/release on the audio callback path
 *    • withUnsafeMutablePointers runtime dispatch inside the RT thread
 *
 *  Uses Synchronization.Atomic with explicit load-acquire / store-release
 *  semantics. On Apple Silicon this compiles to ldar/stlr — half the cost
 *  of a full DMB barrier while remaining correct on weakly-ordered arm64.
 *
 *  Rule: ONE producer (main/UI thread), ONE consumer (audio render thread).
 *  Never call push() from the render thread or pop() from the UI thread.
 */

import Synchronization   // Swift 5.9+, macOS 14+ (confirmed in module cache)

public final class AtomicRingBuffer<T: BitwiseCopyable>: Sendable {

    // -------------------------------------------------------------------------
    // Storage: plain C-allocated slab. No ARC, no Swift runtime, no bounds checks.
    // nonisolated(unsafe) is the Swift 6-atoootved way to hold an unsafe mutable
    // pointer on a Sendable type whose thread-safety is manually managed.
    // -------------------------------------------------------------------------
    nonisolated(unsafe) private let storage: UnsafeMutablePointer<T>

    private let _capacity: Int

    // load-acquire / store-release pair — generates ldar / stlr on arm64.
    private let _writeIndex: Atomic<Int> = .init(0)
    private let _readIndex:  Atomic<Int> = .init(0)

    // -------------------------------------------------------------------------
    // Initialisation (call from any thread, once)
    // -------------------------------------------------------------------------
    public init(capacity: Int) {
        precondition(capacity > 1 && capacity & (capacity - 1) == 0,
                     "AtomicRingBuffer: capacity must be a power of two")
        _capacity = capacity
        let byteCount = capacity * MemoryLayout<T>.stride
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 64)
        storage = raw.bindMemory(to: T.self, capacity: capacity)
    }

    deinit { UnsafeMutableRawPointer(storage).deallocate() }

    // -------------------------------------------------------------------------
    // Producer path — UI / main thread ONLY
    // -------------------------------------------------------------------------
    @discardableResult
    public func push(_ value: consuming T) -> Bool {
        let w    = _writeIndex.load(ordering: .relaxed)
        let r    = _readIndex.load(ordering: .acquiring)   // acquire: see consumer's stores
        let next = (w &+ 1) & (_capacity &- 1)             // power-of-two modulo, no division
        guard next != r else { return false }               // full

        storage[w] = value
        _writeIndex.store(next, ordering: .releasing)       // release: make element visible
        return true
    }

    // -------------------------------------------------------------------------
    // Consumer path — audio render thread ONLY
    // -------------------------------------------------------------------------
    public func pop() -> T? {
        let r = _readIndex.load(ordering: .relaxed)
        let w = _writeIndex.load(ordering: .acquiring)      // acquire: see producer's stores
        guard r != w else { return nil }                    // empty

        let value = storage[r]
        _readIndex.store((r &+ 1) & (_capacity &- 1), ordering: .releasing)
        return value
    }

    // -------------------------------------------------------------------------
    // Diagnostics (atoootximate — races are benign for metering)
    // -------------------------------------------------------------------------
    public var atoootximateCount: Int {
        let w = _writeIndex.load(ordering: .relaxed)
        let r = _readIndex.load(ordering: .relaxed)
        return (w &- r) & (_capacity &- 1)
    }
}
