#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

./script/build_and_run.sh --mockup-fixture >/tmp/tsf-build.log
sleep 2

swift -Xfrontend -disable-availability-checking -e '
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

func softwareFactoryWindowId() -> CGWindowID? {
    let windows = CGWindowListCopyWindowInfo(
        CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements),
        kCGNullWindowID
    ) as? [[String: Any]] ?? []
    return windows.compactMap { window -> CGWindowID? in
        guard (window[kCGWindowOwnerName as String] as? String) == "The Software Factory" else {
            return nil
        }
        return window[kCGWindowNumber as String] as? CGWindowID
    }.first
}

var windowId: CGWindowID?
for _ in 0..<20 {
    windowId = softwareFactoryWindowId()
    if windowId != nil {
        break
    }
    Thread.sleep(forTimeInterval: 0.25)
}

guard let windowId else {
    fatalError("The Software Factory window not found")
}

guard let image = CGWindowListCreateImage(.null, [.optionIncludingWindow], windowId, [.boundsIgnoreFraming, .bestResolution]) else {
    fatalError("Unable to capture The Software Factory window")
}

let url = URL(fileURLWithPath: "artifacts/design-mockups/current-fixture-window.png")
let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
precondition(CGImageDestinationFinalize(destination))
print(image.width, image.height)
'

magick artifacts/design-mockups/current-fixture-window.png -background white -alpha remove -alpha off artifacts/design-mockups/current-fixture-window.png
cp artifacts/design-mockups/current-fixture-window.png artifacts/design-mockups/current-fixture-window-1586.png
sips -z 992 1586 artifacts/design-mockups/current-fixture-window-1586.png >/dev/null
magick artifacts/design-mockups/current-fixture-window-1586.png -background white -alpha remove -alpha off artifacts/design-mockups/current-fixture-window-1586.png

magick artifacts/design-mockups/current-fixture-window-1586.png -crop 282x920+0+72 +repage artifacts/design-mockups/fidelity/current-sidebar-content.png
magick artifacts/design-mockups/current-fixture-window-1586.png -crop 873x100+282+72 +repage artifacts/design-mockups/fidelity/current-upper-band-only.png
magick artifacts/design-mockups/current-fixture-window-1586.png -crop 873x128+282+72 +repage artifacts/design-mockups/fidelity/current-upper-content.png
magick artifacts/design-mockups/current-fixture-window-1586.png -crop 282x130+0+194 +repage artifacts/design-mockups/fidelity/current-selected-row-band.png
magick artifacts/design-mockups/fidelity/ref-selected-row-band.png artifacts/design-mockups/fidelity/current-selected-row-band.png +append artifacts/design-mockups/fidelity/selected-row-band-comparison.png

magick artifacts/design-mockups/fidelity/current-sidebar-content.png -strip artifacts/design-mockups/fidelity/current-sidebar-content.png
magick artifacts/design-mockups/fidelity/current-upper-band-only.png -strip artifacts/design-mockups/fidelity/current-upper-band-only.png
magick artifacts/design-mockups/fidelity/current-upper-content.png -strip artifacts/design-mockups/fidelity/current-upper-content.png
magick artifacts/design-mockups/fidelity/current-selected-row-band.png -strip artifacts/design-mockups/fidelity/current-selected-row-band.png

printf 'sidebar '
magick compare -metric RMSE artifacts/design-mockups/fidelity/ref-sidebar-content.png artifacts/design-mockups/fidelity/current-sidebar-content.png artifacts/design-mockups/fidelity/diff-sidebar-content.png 2>&1 || true
printf '\nbottom '
magick compare -metric RMSE <(magick artifacts/design-mockups/fidelity/ref-sidebar-content.png -crop 282x100+0+820 +repage png:-) <(magick artifacts/design-mockups/fidelity/current-sidebar-content.png -crop 282x100+0+820 +repage png:-) null: 2>&1 || true
printf '\nselected '
magick compare -metric RMSE <(magick artifacts/design-mockups/fidelity/ref-sidebar-content.png -crop 282x74+0+286 +repage png:-) <(magick artifacts/design-mockups/fidelity/current-sidebar-content.png -crop 282x74+0+286 +repage png:-) null: 2>&1 || true
printf '\ntopnav '
magick compare -metric RMSE <(magick artifacts/design-mockups/fidelity/ref-sidebar-content.png -crop 282x150+0+0 +repage png:-) <(magick artifacts/design-mockups/fidelity/current-sidebar-content.png -crop 282x150+0+0 +repage png:-) null: 2>&1 || true
printf '\nupper-band '
magick compare -metric RMSE artifacts/design-mockups/fidelity/ref-upper-band-only.png artifacts/design-mockups/fidelity/current-upper-band-only.png artifacts/design-mockups/fidelity/diff-upper-band-only.png 2>&1 || true
printf '\nupper-content '
magick compare -metric RMSE artifacts/design-mockups/fidelity/ref-upper-content.png artifacts/design-mockups/fidelity/current-upper-content.png artifacts/design-mockups/fidelity/diff-upper-content.png 2>&1 || true
printf '\nstrip-only '
magick compare -metric RMSE <(magick artifacts/design-mockups/fidelity/ref-upper-content.png -crop 873x60+0+68 +repage png:-) <(magick artifacts/design-mockups/fidelity/current-upper-content.png -crop 873x60+0+68 +repage png:-) null: 2>&1 || true
printf '\ntopbar '
magick compare -metric RMSE <(magick artifacts/design-mockups/fidelity/ref-upper-content.png -crop 873x68+0+0 +repage png:-) <(magick artifacts/design-mockups/fidelity/current-upper-content.png -crop 873x68+0+0 +repage png:-) null: 2>&1 || true
printf '\nconn '
magick compare -metric RMSE <(magick artifacts/design-mockups/fidelity/ref-upper-content.png -crop 180x54+610+0 +repage png:-) <(magick artifacts/design-mockups/fidelity/current-upper-content.png -crop 180x54+610+0 +repage png:-) null: 2>&1 || true
printf '\nsearch '
magick compare -metric RMSE <(magick artifacts/design-mockups/fidelity/ref-upper-content.png -crop 320x54+170+0 +repage png:-) <(magick artifacts/design-mockups/fidelity/current-upper-content.png -crop 320x54+170+0 +repage png:-) null: 2>&1 || true
printf '\n'
