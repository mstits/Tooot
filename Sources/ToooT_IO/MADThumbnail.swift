/*
 *  PROJECT ToooT (ToooT_IO)
 *  PNG thumbnail renderer for `.mad` / `.mod` files.
 *
 *  Renders a tile-style "what's in this file" preview the way OpenMPT and
 *  Renoise do: each cell is one (row, channel) of the first pattern; cell
 *  intensity scales with note presence. Pure CoreGraphics — no AppKit, so
 *  this is callable from a Quick Look extension target.
 *
 *  The Quick Look extension wraps `MADThumbnail.renderPNG(url:size:)` to
 *  satisfy `QLThumbnailProvider.provideThumbnail(for:)`. Spotlight's
 *  separate `mdimporter` consumes `MADMetadata.read(url:)` only — they
 *  share zero state.
 */

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ToooT_Core

public enum MADThumbnail {

    /// Renders a square thumbnail for `url`. Returns PNG-encoded bytes, or nil
    /// if the file cannot be parsed. Safe to call off the main thread.
    public static func renderPNG(url: URL, size: Int = 256) -> Data? {
        guard let cg = renderCGImage(url: url, size: size) else { return nil }
        return encodePNG(cg)
    }

    /// CGImage variant for callers who want to draw the result somewhere
    /// (e.g. a Quick Look extension's QLPreviewProvider).
    public static func renderCGImage(url: URL, size: Int) -> CGImage? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count > 4 else { return nil }
        let sig4 = String(data: data[0..<4], encoding: .ascii) ?? ""
        let densityGrid: [[Float]]
        if sig4 == "MADK" || sig4 == "MADG" || sig4 == "Tooo" {
            densityGrid = madDensityGrid(data: data) ?? emptyGrid()
        } else if data.count >= 1084,
                  let marker = String(data: data[1080..<1084], encoding: .ascii),
                  marker.first != nil {
            densityGrid = modDensityGrid(data: data, marker: marker) ?? emptyGrid()
        } else {
            return nil
        }

        return drawGrid(densityGrid, size: size)
    }

    // MARK: - PNG encoding

    private static func encodePNG(_ cg: CGImage) -> Data? {
        let mutableData = NSMutableData()
        let utType = UTType.png.identifier as CFString
        guard let dest = CGImageDestinationCreateWithData(mutableData, utType, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return mutableData as Data
    }

    // MARK: - Drawing

    private static func drawGrid(_ grid: [[Float]], size: Int) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        // Background: dark studio gray.
        ctx.setFillColor(CGColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

        let rows = grid.count
        let cols = grid.first?.count ?? 0
        guard rows > 0, cols > 0 else { return ctx.makeImage() }

        let cellW = CGFloat(size) / CGFloat(cols)
        let cellH = CGFloat(size) / CGFloat(rows)

        for r in 0..<rows {
            for c in 0..<cols {
                let v = grid[r][c]
                if v > 0 {
                    // Carbon teal scaled by intensity — matches the studio theme.
                    let intensity = Double(min(1.0, max(0.15, v)))
                    ctx.setFillColor(CGColor(red: 0.20 + 0.15 * intensity,
                                             green: 0.85 * intensity,
                                             blue:  0.75 * intensity,
                                             alpha: 1.0))
                    let rect = CGRect(
                        x: CGFloat(c) * cellW + 0.5,
                        y: CGFloat(rows - 1 - r) * cellH + 0.5,
                        width: cellW - 1.0,
                        height: cellH - 1.0)
                    ctx.fill(rect)
                }
            }
        }

        return ctx.makeImage()
    }

    // MARK: - Density extraction

    private static func emptyGrid() -> [[Float]] {
        Array(repeating: Array(repeating: 0, count: 8), count: 32)
    }

    private static func madDensityGrid(data: Data) -> [[Float]]? {
        let metaOffset = 4 + 32 + 239 + 3 + 8 + 3 + 3
        guard data.count > metaOffset + 5 + 999 else { return nil }
        let numPat = Int(data[metaOffset])
        let numChn = Int(data[metaOffset + 1])
        guard numPat > 0, numChn > 0 else { return nil }

        // First pattern only — preview is meant to be glanceable.
        let patStart = metaOffset + 5 + 999
        let cols = min(numChn, 32)
        let rows = 64
        var grid = Array(repeating: Array(repeating: Float(0), count: cols), count: rows)
        for r in 0..<rows {
            for c in 0..<cols {
                let off = patStart + (r * numChn + c) * 5
                guard off + 4 < data.count else { break }
                let note = data[off]
                let inst = data[off + 1]
                let cmd  = data[off + 3]
                let info = data[off + 4]
                if note > 0 || inst > 0 || cmd > 0 || info > 0 {
                    grid[r][c] = note > 0 ? min(1.0, Float(note) / 96.0 + 0.4) : 0.5
                }
            }
        }
        return grid
    }

    private static func modDensityGrid(data: Data, marker: String) -> [[Float]]? {
        let knownChannels: [String: Int] = [
            "M.K.": 4, "M!K!": 4, "FLT4": 4, "4CHN": 4,
            "6CHN": 6, "FLT8": 8, "8CHN": 8, "2CHN": 2
        ]
        let cols: Int
        if let known = knownChannels[marker] {
            cols = known
        } else if let n = Int(marker.prefix(2)), n > 0 {
            cols = n
        } else if let n = Int(marker.prefix(1)), n > 0 {
            cols = n
        } else {
            cols = 4
        }
        guard cols > 0 else { return nil }

        let patOffset = 1084
        let rows = 64
        var grid = Array(repeating: Array(repeating: Float(0), count: min(cols, 32)),
                         count: rows)
        for r in 0..<rows {
            for c in 0..<min(cols, 32) {
                let off = patOffset + (r * cols + c) * 4
                guard off + 3 < data.count else { break }
                let b0 = Int(data[off]), b1 = Int(data[off + 1])
                let b2 = Int(data[off + 2]), b3 = Int(data[off + 3])
                let period = (b0 & 0x0F) << 8 | b1
                let inst   = ((b0 & 0xF0) >> 0) | ((b2 & 0xF0) >> 4)
                let effect = b2 & 0x0F
                if period > 0 || inst > 0 || effect > 0 || b3 > 0 {
                    grid[r][c] = period > 0 ? 0.85 : 0.4
                }
            }
        }
        return grid
    }
}
