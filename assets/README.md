# ClaudeS — icon assets

Design kit reduced to what the project actually uses, plus the source
art (in case something needs regenerating). The original kit delivered
by the design AI had ~155 files (derived sizes/formats for Xcode,
Flutter, web, monochrome, etc.) — deliberately removed: none of that is
consumed by the build or the code today.

## Structure

- `source/` — high-resolution source art. If any icon ever needs to
  be regenerated at another size/format, this is the starting point.
- `ClaudeS.icns` — the app's real icon (Dock, Finder, Cmd+Tab, the About
  panel). `scripts/build-app.sh` copies this file straight into
  `Contents/Resources/AppIcon.icns` when packaging — the single source,
  no duplicate copy in `Packaging/`.
- `ClaudeS.png` — the same art as a plain PNG (1024px), useful for
  README/GitHub.
- `ClaudeS-rounded.png` — the actual macOS-rendered icon (squircle mask,
  shading and all), extracted once via `QLThumbnailGenerator` (the same
  pipeline the Finder/Dock use to draw app icons) against the built
  `ClaudeS.app`, instead of approximating the curve by hand. Used anywhere
  that doesn't apply the OS mask itself, like the README on GitHub.
- `menu-bar/status-bar-template-64.png` — the source of the menu
  bar icon in use (see the section below). The only file kept from that
  folder of the original kit; the rest of it (the white variant, other
  sizes) isn't used.
- `screenshots/` — app screenshots embedded in the top-level README.

## Status bar icon

`Sources/ClaudeSApp/Resources/StatusBarIcon.png` (what the app actually
uses in the menu bar) was manually cropped from
`menu-bar/status-bar-template-64.png` (the *template* variant,
black with alpha) — that 64px PNG had ~22-39% of transparent padding
around the artwork, which made the icon look smaller than its neighbors
in the real menu bar; the crop ended up at 54×43px.

`StatusBarController.swift` loads `StatusBarIcon.png` with `isTemplate =
true` (AppKit adapts the color for light/dark) and fixes the displayed
height at 16pt, deriving the width from the crop's aspect ratio (~1.26:1)
instead of forcing a square that would distort the artwork.

Palette: Claude orange #D97757, warm white, and dark graphite.
