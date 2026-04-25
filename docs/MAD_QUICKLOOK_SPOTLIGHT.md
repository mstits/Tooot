# Quick Look + Spotlight extensions for `.mad`

ToooT ships the data-extraction primitives needed to power both extensions:

| Extension              | Bundle type        | Primitive used                          |
|------------------------|--------------------|------------------------------------------|
| Spotlight (search)     | `.mdimporter`      | `MADMetadataReader.read(url:)`           |
| Quick Look (preview)   | `.appex` (QLPreview) | `MADThumbnail.renderPNG(url:size:)`    |

Both primitives live in `ToooT_IO`. They depend only on Foundation +
CoreGraphics + ImageIO — no AppKit, no SwiftUI — so they drop into either
extension target unmodified.

## Why this isn't a Swift Package target

Swift Package Manager does not build `.appex` or `.mdimporter` bundles
directly. Both are macOS plug-in bundle types that require an Xcode
project (or a hand-rolled `xcodebuild` invocation) to produce a
correctly-signed plug-in bundle with the right `Info.plist` keys.

The data extraction is the hard part. Wrapping it in the extension is
mechanical — see the templates below.

## Quick Look extension (.appex)

1. In Xcode, add a new target → **macOS → Quick Look Preview Extension**.
2. Replace the generated provider with:

```swift
import QuickLook
import ToooT_IO

final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        QLPreviewReply(contextSize: CGSize(width: 512, height: 512),
                       isBitmap: true) { ctx in
            guard let cg = MADThumbnail.renderCGImage(url: request.fileURL, size: 512)
            else { return }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 512, height: 512))
        }
    }
}
```

3. In the extension's `Info.plist`:
   - `QLSupportedContentTypes`: `["com.apple.projecttooot.mad"]`
   - `NSExtensionPrincipalClass`: `$(PRODUCT_MODULE_NAME).PreviewProvider`

## Spotlight `.mdimporter`

`.mdimporter` is an older C plug-in API. The simplest path is to ship a
small helper executable that reads a file, converts the metadata to
JSON, and have a thin Obj-C `.mdimporter` shell out to it.

The Obj-C side calls:

```objc
NSString *jsonPath = [@"/Applications/ToooT.app/Contents/MacOS/tooot-mdls"];
// run with file path argument, parse JSON, populate attributes dict:
//   - kMDItemTitle               ← MADMetadata.title
//   - kMDItemDescription         ← "<format>, <patterns>p, <channels>ch, <instruments>i"
//   - kMDItemMusicalInstruments  ← MADMetadata.instrumentNames
//   - kMDItemFSSize              ← MADMetadata.fileSizeBytes
```

Building `tooot-mdls` is just a CLI executable target wrapping
`MADMetadataReader.read(url:)` and JSON-encoding the result. Pure
Foundation, no UI dependencies — drop it next to `ProjectToooTApp` in
`Package.swift` whenever the importer ships.

## When to actually ship these

Both extensions are quality-of-life features. They're worth wrapping when:

- ToooT is being distributed via the Mac App Store (Spotlight indexing
  is one of the things reviewers expect of native document apps).
- A user reports they want to preview / search projects without
  launching ToooT.

Until then, the primitives sitting in `ToooT_IO` are the load-bearing
work. Wrapping them is an afternoon, not a sprint.
