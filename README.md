# Music Vinyl

A small macOS app that shows whatever Apple Music is playing as a spinning
record: the album art becomes the label, and a tonearm tracks inward as the
song plays.

## Build and run

```bash
./build.sh && open "build/Music Vinyl.app"
```

The first launch asks for permission to control Music (System Settings →
Privacy & Security → Automation). That prompt is required — it is how the app
reads the current track. Deny it and the record will just sit still.

## Using it

- **Drag anywhere** on the window to move it. There is no title bar.
- **Hover** over the record for play/pause and skip buttons.
- **Right-click** for always-on-top, track info, and turntable speed
  (33⅓ / 45 / 78 RPM — 33⅓ is the real speed, and it is fast).
- **Quit** with ⌘Q, or from the right-click menu. The close button is hidden.
- Drag a window corner to resize; the record scales with it.

## How it works

| Piece | What it does |
| --- | --- |
| `MusicBridge.swift` | Apple events to Music.app: track info, artwork, transport |
| `NowPlayingModel.swift` | Polls state, derives rotation angle from wall-clock time |
| `VinylView.swift` | Draws the disc, grooves, label, and tonearm |
| `ContentView.swift` | Layout, hover controls, window chrome removal |

Track changes arrive instantly over Music's `com.apple.Music.playerInfo`
distributed notification; a 1–2.5 s poll keeps the playback position (and so
the tonearm) in sync.

Rotation is computed from elapsed wall-clock time rather than accumulated per
frame, so pausing freezes the label exactly where it was and dropped frames
never make the record drift.

## Development helpers

The binary has two flags used while building the artwork, so the record can be
checked without launching a window:

```bash
./build.sh
"build/Music Vinyl.app/Contents/MacOS/MusicVinyl" --dump-state
```

- `--dump-state` — print what Music currently reports and exit.
- `--render-preview out.png` — render the record offscreen to a PNG.
  `PREVIEW_ANGLE`, `PREVIEW_PROGRESS`, and `PREVIEW_NOART=1` control the frame.

`./make-icon.sh` regenerates `Resources/AppIcon.icns` from the same SwiftUI
code that draws the record.

## Requirements

macOS 14+, Swift 6 toolchain (Xcode 15+). No third-party dependencies.
