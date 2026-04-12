/*
 *  NextGenTracker (LegacyTracker 2026)
 *  Copyright (c) 2026. All rights reserved.
 *  Transitioning legacy tracker logic to Swift 6.
 */

import Metal

// MARK: - Cell data layout (must match PatternCellBuffer on the Swift side)
//
// Each cell is packed into 4 bytes (UInt32), written by the CPU into a
// MTLBuffer with .storageModeShared and read every frame by the GPU.
// No texture generation step — pattern changes are a memcpy of ≤ 64 KB.
//
// Bit layout (LSB first):
//   [7:0]   note       (0 = empty, 1-120 = MIDI note number)
//   [15:8]  instrument (0 = none)
//   [23:16] effect     (effect command byte)
//   [31:24] effectParam
//
// GPU reads this buffer to determine cell color and visual density.

// MARK: - ScrollUniforms (Swift-side mirror, passed via setVertexBytes / setFragmentBytes)
//
// struct PatternScrollUniforms {
//     float  fractionalRowOffset;   // sub-row scroll position [0, 1)
//     float  currentEngineRow;      // integer row the playhead is on
//     uint   totalRows;             // rows in the current pattern (always 64)
//     uint   totalChannels;         // columns in view (1-256)
//     uint   visibleRows;           // rows visible on screen
//     uint   cursorChannel;         // cursor X
//     uint   cursorRow;             // cursor Y
//     float  cellWidth;             // NDC width of one channel column
//     float  cellHeight;            // NDC height of one row
// };

public struct Shaders {
    public static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // ─────────────────────────────────────────────────────────────────────────
    // Shared types
    // ─────────────────────────────────────────────────────────────────────────

    struct VertexOut {
        float4 position [[position]];
        float  intensity;
    };

    struct GridVertexOut {
        float4 position  [[position]];
        float2 cellUV;        // [0,1] within the current cell
        float2 screenUV;      // [0,1] across the full view
        uint   instanceID [[flat]];
    };

    struct PatternScrollUniforms {
        float fractionalRowOffset;
        float currentEngineRow;
        uint  totalRows;
        uint  totalChannels;
        uint  visibleRows;
        uint  cursorChannel;
        uint  cursorRow;
        float cellWidth;     // NDC units
        float cellHeight;    // NDC units
        float channelOffset;
    };

    // ─────────────────────────────────────────────────────────────────────────
    // Spectrogram (waveform visualiser) — unchanged functional behaviour
    // ─────────────────────────────────────────────────────────────────────────

    vertex VertexOut spectrogram_vertex(
        uint            vertexID    [[vertex_id]],
        constant float* audioSamples [[buffer(0)]])
    {
        VertexOut out;
        float x      = (float(vertexID) / 1024.0) * 2.0 - 1.0;
        float y      = audioSamples[vertexID] * 0.8;
        out.position = float4(x, y, 0.0, 1.0);
        out.intensity = abs(y);
        return out;
    }

    fragment float4 spectrogram_fragment(VertexOut in [[stage_in]]) {
        float glow  = clamp(in.intensity * 2.5, 0.1, 1.0);
        float3 color = mix(float3(0.0, 0.8, 1.0), float3(1.0, 0.1, 0.6), glow);
        return float4(color * glow, 1.0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Pattern Grid — 120Hz GPU-native instanced cell renderer
    //
    // ONE draw call:  drawPrimitives(.triangleStrip, vertexStart: 0,
    //                               vertexCount: 4,
    //                               instanceCount: totalChannels * visibleRows)
    //
    // The vertex shader maps each instance to a screen-space quad.
    // The fragment shader reads the cell data buffer and renders:
    //   • Procedural background grid + beat highlights  (always)
    //   • Note presence pill                            (if note != 0)
    //   • Effect indicator dot                          (if effect != 0)
    //   • Playhead row highlight                        (smooth, sub-pixel)
    //   • Cursor outline                                (GPU, no CPU involvement)
    //
    // Key 120Hz property: fractionalRowOffset is the ONLY thing that changes
    // every frame.  All other uniforms change ≤ once per sequencer row step.
    // The cell data buffer is updated with a plain memcpy when the pattern
    // changes — no texture generation, no CoreGraphics, no NSAttributedString.
    // ─────────────────────────────────────────────────────────────────────────

    vertex GridVertexOut grid_vertex(
        uint                         vid        [[vertex_id]],
        uint                         instanceID [[instance_id]],
        constant PatternScrollUniforms& u        [[buffer(0)]])
    {
        // ── Decode instance to (channel, visibleRowSlot) ─────────────────────
        uint ch       = instanceID % u.totalChannels;
        uint rowSlot  = instanceID / u.totalChannels;   // 0 .. visibleRows (inclusive — extra slot for seamless wrap)

        // ── Compute which actual pattern row this slot maps to ───────────────
        // fractionalRowOffset ∈ [0,1): sub-row scroll.
        // SIGN IS CRITICAL: subtracting frac scrolls the grid UPWARD as frac
        // increases — new rows arrive from below, old rows depart off the top.
        // (Adding frac was the original bug: it scrolled DOWN, creating a
        // sawtooth snap at every row boundary that produced the 3Hz oscillation.)
        float slotWithFrac = float(rowSlot) - u.fractionalRowOffset;

        // ── Build the NDC quad for this cell ─────────────────────────────────
        // NDC: (-1,-1) = bottom-left, (1,1) = top-right.
        float2 quadPos[4] = {
            float2(0.0, 0.0), float2(1.0, 0.0),
            float2(0.0, 1.0), float2(1.0, 1.0)
        };
        float2 local = quadPos[vid];   // [0,1] within the cell

        // Cell origin in NDC space
        float ndcLeft = -1.0 + (float(ch) - u.channelOffset) * u.cellWidth;
        // Flip Y: row 0 at top, visibleRows-1 at bottom.
        float ndcTop  =  1.0 - slotWithFrac * u.cellHeight;

        float2 ndcPos = float2(ndcLeft + local.x * u.cellWidth,
                               ndcTop  - local.y * u.cellHeight);

        GridVertexOut out;
        out.position  = float4(ndcPos, 0.0, 1.0);
        out.cellUV    = local;
        // screenUV for the full-screen effects (playhead etc.)
        out.screenUV  = float2((ndcPos.x + 1.0) * 0.5,
                               (1.0 - ndcPos.y) * 0.5);
        out.instanceID = instanceID;
        return out;
    }

    // ── Helper: smooth border mask ───────────────────────────────────────────
    // Returns 1.0 on the edge (within `t` UV units), 0.0 in the interior.
    static float borderMask(float2 uv, float t) {
        float2 edge = step(uv, float2(t)) + step(1.0 - t, uv);
        return clamp(edge.x + edge.y, 0.0, 1.0);
    }

    // ── Helper: note-type colour ─────────────────────────────────────────────
    // note 1-35   → bass range  → teal
    // note 36-59  → mid range   → cyan-blue
    // note 60-83  → treble      → magenta-pink
    // note 84+    → ultra high  → gold
    static float3 noteColor(uint note) {
        if (note == 0)   return float3(0.0);
        if (note < 36)   return float3(0.0, 0.9, 0.7);
        if (note < 60)   return float3(0.0, 0.6, 1.0);
        if (note < 84)   return float3(0.9, 0.2, 0.8);
        return float3(1.0, 0.8, 0.1);
    }

    fragment float4 grid_fragment(
        GridVertexOut               in         [[stage_in]],
        constant PatternScrollUniforms& u      [[buffer(0)]],
        constant uint*              cellData   [[buffer(1)]])
    {
        uint ch      = in.instanceID % u.totalChannels;
        uint rowSlot = in.instanceID / u.totalChannels;

        // Actual pattern row (integer, for data lookup).
        // fractionalRowOffset must NOT appear here — the slot's row DATA is fixed
        // for the entire duration of a row; only its NDC POSITION moves.
        // Including frac here caused two adjacent rows' data to blend/straddle,
        // producing a second visual artifact on top of the vertex sign bug.
        float engineRowF = float(u.currentEngineRow)
                         - float(u.visibleRows / 2)
                         + float(rowSlot);
        int   patRow     = (int(round(engineRowF))) & 63;

        // ── Optimized Background ─────────────────────────────────────────────
        float3 bg = mix(float3(0.05, 0.05, 0.07), float3(0.07, 0.07, 0.10), float(patRow % 4 == 0));

        // Separators using smoothstep for cleaner 1px lines
        float sep = step(0.97, in.cellUV.x);
        float rowSep = step(0.96, in.cellUV.y);
        bg = mix(bg, float3(0.02, 0.02, 0.03), max(sep, rowSep));

        float4 color = float4(bg, 1.0);

        // ── Optimized Data Fetch ─────────────────────────────────────────────
        uint packed = cellData[uint(patRow) * u.totalChannels + ch];
        if (packed != 0) {
            uint note       = (packed >>  0) & 0xFF;
            uint instrument = (packed >>  8) & 0xFF;
            uint effect     = (packed >> 16) & 0xFF;

            // ── Note pill (Branchless-ish) ───────────────────────────────────
            if (note != 0) {
                bool inPill = (in.cellUV.x >= 0.04 && in.cellUV.x <= 0.65 &&
                               in.cellUV.y >= 0.15 && in.cellUV.y <= 0.85);
                if (inPill) {
                    float3 nc = noteColor(note);
                    color = float4(nc * (0.7 + 0.3 * (1.0 - (in.cellUV.x - 0.04)/0.61)), 1.0);
                }
            }

            // ── Effect dot ───────────────────────────────────────────────────
            if (effect != 0) {
                float2 dotUV = float2((in.cellUV.x - 0.70) / 0.25, (in.cellUV.y - 0.08) / 0.30);
                float  dotR  = length(dotUV - 0.5) * 2.0;
                color = mix(color, float4(1.0, 0.7, 0.1, 1.0), (1.0 - smoothstep(0.6, 1.0, dotR)) * 0.9);
            }

            // ── Instrument tint ──────────────────────────────────────────────
            if (instrument != 0 && note == 0) {
                float hue = fmod(float(instrument) * 0.137, 1.0);
                float3 p = abs(fract(float3(hue) + float3(1.0, 2.0/3.0, 1.0/3.0)) * 6.0 - 3.0);
                color.rgb += 0.036 * mix(float3(1.0), clamp(p - 1.0, 0.0, 1.0), 0.3);
            }
        }

        // ── Playhead highlight ───────────────────────────────────────────────
        // Use screen-UV Y distance from 0.5 (physical center of the view).
        // This is independent of frac/slot math — the highlight is always at the
        // exact center of the screen regardless of sub-row scroll position.
        // The SwiftUI PlayheadOverlayView draws the crisp indicator line on top.
        float distFromCenter = abs(in.screenUV.y - 0.5) * float(u.visibleRows);
        color = mix(color, float4(0.0, 0.55, 1.0, 1.0), (1.0 - smoothstep(0.0, 0.7, distFromCenter)) * 0.28);

        // ── Cursor border ────────────────────────────────────────────────────
        if (ch == u.cursorChannel && uint(patRow) == u.cursorRow) {
            float2 edge2 = step(in.cellUV, float2(0.07)) + step(0.93, in.cellUV);
            color = mix(color, float4(1.0, 0.9, 0.0, 1.0), clamp(edge2.x + edge2.y, 0.0, 1.0) * 0.9);
        }

        return color;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Legacy grid_vertex / grid_fragment (texture-based path, kept for compat)
    // These are no longer called by the primary renderer but may be used by
    // the export / offline thumbnail generator.
    // ─────────────────────────────────────────────────────────────────────────

    struct LegacyGridVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex LegacyGridVertexOut grid_vertex_legacy(uint vid [[vertex_id]]) {
        float2 pos[4] = { float2(-1,-1), float2(-1,1), float2(1,-1), float2(1,1) };
        LegacyGridVertexOut out;
        out.position = float4(pos[vid], 0.0, 1.0);
        out.uv = pos[vid] * 0.5 + 0.5;
        out.uv.y = 1.0 - out.uv.y;
        return out;
    }

    fragment float4 grid_fragment_legacy(
        LegacyGridVertexOut       in         [[stage_in]],
        texture2d<float>          patternTex [[texture(0)]],
        constant float&           rowOffset  [[buffer(0)]],
        constant uint2&           cursor     [[buffer(1)]])
    {
        float visibleRows    = 20.0;
        float texHeightInRows = 64.0;
        float viewY = (rowOffset / texHeightInRows) + (in.uv.y - 0.5) * (visibleRows / texHeightInRows);
        float3 bg = float3(0.05, 0.05, 0.07);
        float channelWidthUV = 1.0 / 64.0;
        float isChannelLine  = step(0.95, fract(in.uv.x / channelWidthUV));
        // float rowHeightUV    = 1.0 / texHeightInRows;
        float isRowLine      = step(0.92, fract(viewY * texHeightInRows));
        float3 gridColor     = mix(bg, float3(0.15,0.15,0.2), isChannelLine * 0.5 + isRowLine * 0.3);
        float4 texColor      = float4(gridColor, 1.0);
        if (viewY >= 0.0 && viewY <= 1.0) {
            constexpr sampler s(address::clamp_to_edge, filter::linear);
            float4 sn = patternTex.sample(s, float2(in.uv.x, viewY));
            texColor  = mix(texColor, sn, sn.a);
        }
        float dist      = abs(in.uv.y - 0.5);
        float phMask    = step(dist, 0.5 / visibleRows);
        texColor = mix(texColor, float4(0.0, 0.5, 1.0, 0.2), phMask);
        return texColor;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Basidium Engine — Spectral Canvas Additive Oscillator Bank (The Grin)
    //
    // Mission: Equation-Grade Inverse-FFT. 
    // This kernel transforms 2D bitmap data (PNG/Grayscale) into a 512-bin 
    // logarithmic oscillator bank to hide imagery in the spectrogram.
    // ─────────────────────────────────────────────────────────────────────────

    kernel void basidium_spectral_synth(
        texture2d<float, access::read> spectralMap [[texture(0)]],
        device float*                  outputAudio [[buffer(0)]],
        constant float&                currentTime [[buffer(1)]],
        constant float&                sampleRate  [[buffer(2)]],
        uint                           tid         [[thread_position_in_grid]])
    {
        if (tid >= 512) return;

        // Logarithmic frequency spread: f = fmin * (fmax/fmin)^(bin/bins)
        // Ensures the image integrity is preserved in a logarithmic spectrogram.
        float fMin = 40.0;
        float fMax = 20000.0;
        float freq = fMin * pow(fMax / fMin, float(tid) / 512.0);
        
        // Horizontal scan: map currentTime to texture X coord
        // We assume the texture represents a fixed duration of time.
        uint texW = spectralMap.get_width();
        uint x = uint(fract(currentTime * 0.1) * float(texW)); 
        
        // Vertical scan: map bin to texture Y coord (flipped)
        uint texH = spectralMap.get_height();
        uint y = texH - 1 - uint((float(tid) / 512.0) * float(texH));
        
        float amplitude = spectralMap.read(uint2(x, y)).r;
        
        // Phase coherence is maintained by using absolute currentTime
        float phase = 2.0 * 3.14159265 * freq * currentTime;
        float sample = sin(phase) * amplitude * (1.0 / 512.0);
        
        outputAudio[tid] = sample;
    }

    kernel void basidium_sum_spectral(
        device const float* binAudio   [[buffer(0)]],
        device float*       finalOut   [[buffer(1)]],
        uint                tid        [[thread_position_in_grid]])
    {
        // One thread per block (e.g. 512 samples) - naive sum for the first pass.
        // In a production "Brutalist" implementation, this would be a parallel reduction.
        if (tid != 0) return;
        
        float sum = 0;
        for (int i = 0; i < 512; i++) {
            sum += binAudio[i];
        }
        *finalOut = sum;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Dynamic Spectral Encoding (Live Video to 512-Bin Frequency Data)
    // ─────────────────────────────────────────────────────────────────────────

    kernel void dynamic_spectral_encoding(
        texture2d<float, access::read> videoFrame [[texture(0)]],
        device float*                  outputFFT  [[buffer(0)]],
        uint2                          tid        [[thread_position_in_grid]])
    {
        if (tid.x >= 512 || tid.y != 0) return;

        uint texW = videoFrame.get_width();
        uint texH = videoFrame.get_height();

        // Sum a column of video to extract a rudimentary frequency magnitude
        float colSum = 0;
        uint x = uint((float(tid.x) / 512.0) * float(texW));
        for (uint y = 0; y < texH; y++) {
            // Read luminance (grayscale)
            float3 rgb = videoFrame.read(uint2(x, y)).rgb;
            float lum = dot(rgb, float3(0.299, 0.587, 0.114));
            colSum += lum;
        }

        // Average and store into FFT bin
        outputFFT[tid.x] = colSum / float(texH);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Spectral Bitmap-to-Frequency (Inverse FFT / Additive Mesh)
    // 1024 channels represented as 3D meshlets, jittered by real-time RMS/FFT data
    // ─────────────────────────────────────────────────────────────────────────
    struct SpectralVertexOut {
        float4 position [[position]];
        float amplitude;
        float frequency;
    };

    vertex SpectralVertexOut basidium_spectral_mesh(
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]],
        constant float* rmsData [[buffer(0)]],
        constant float* fftData [[buffer(1)]])
    {
        SpectralVertexOut out;

        // Mathematical cruelty: Jitter the vertices using heavily distorted instance IDs
        float noise = fract(sin(dot(float2(instanceID, vertexID), float2(12.9898, 78.233))) * 43758.5453);
        float channelRMS = rmsData[instanceID % 1024];
        float channelFFT = fftData[vertexID % 512];

        // Extrude based on amplitude
        float3 pos = float3(
            float(instanceID) * 0.1,
            channelRMS * channelFFT * 10.0 * noise,
            float(vertexID) * 0.01
        );

        out.position = float4(pos, 1.0);
        out.amplitude = channelRMS;
        out.frequency = channelFFT;
        return out;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Phase 5: 3D Spatial Field Mesh Shader (M-Series Object Shading)
    // 1024-Channel Swarm visualizer in a shifting geometric cloud
    // ─────────────────────────────────────────────────────────────────────────
    struct SpatialPayload {
        float3 position;
        float scale;
    };

    [[mesh]] void spatial_mesh_shader(mesh<SpectralVertexOut, void, 64, 126, topology::triangle> output,
                                      uint gid [[threadgroup_position_in_grid]],
                                      uint tid [[thread_index_in_threadgroup]],
                                      constant SpatialPayload* nodes [[buffer(0)]])
    {
        if (tid == 0) {
            output.set_primitive_count(126);
        }

        SpatialPayload payload = nodes[gid % 1024];
        float3 basePos = payload.position;
        float radius = payload.scale;

        // The Swarm: Generate jagged geometric meshlets for each 1024 channel
        float phi = float(tid) * 2.3999632; // Golden angle
        float z = 1.0 - (float(tid) / 64.0) * 2.0;
        float r = sqrt(1.0 - z*z);
        float x = r * cos(phi);
        float y = r * sin(phi);

        float3 localPos = float3(x, y, z) * radius;

        SpectralVertexOut v;
        v.position = float4(basePos + localPos, 1.0);
        v.amplitude = radius;
        v.frequency = 440.0;
        
        output.set_vertex(tid, v);
    }

    fragment float4 spatial_fragment(SpectralVertexOut in [[stage_in]]) {
        // Glowing cyan/magenta nodes based on amplitude
        float glow = clamp(in.amplitude * 10.0, 0.2, 1.0);
        float3 color = mix(float3(0.0, 0.8, 1.0), float3(1.0, 0.1, 0.6), in.amplitude * 5.0);
        return float4(color * glow, 1.0);
    }
    """
}
