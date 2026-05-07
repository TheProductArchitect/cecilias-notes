# AppIcon.appiconset

The PNG files referenced in `Contents.json` are produced from
`DesignSystem/InkIconRenderer.swift`. They are **not** committed to the
repository — generating them requires UIKit at build time.

## How to populate

Run this once after creating the Xcode project, from the simulator host or any
iOS target that links `InkIconRenderer`:

```swift
import UIKit
let renderer = InkIconRenderer()
let outDir = URL(fileURLWithPath: "/path/to/Resources/Assets.xcassets/AppIcon.appiconset")
for (px, name) in InkIconRenderer.assetSizes {
    let img = renderer.render(
        size: CGSize(width: px, height: px),
        theme: .light,
        cornerRadius: 0   // iOS applies the icon mask itself; export square
    )
    if let data = img.pngData() {
        try? data.write(to: outDir.appendingPathComponent("\(name).png"))
    }
}
```

For dark + tinted variants (iOS 18+), repeat with `theme: .dark` / `theme: .tinted`
into the appropriate appearance slots in the asset catalog (this requires
editing `Contents.json` to add `appearances` entries — see Apple's docs).
