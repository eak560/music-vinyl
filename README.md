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

- **Click the tonearm** to lift the needle off the record. Playback stops and
  the arm swings back to its rest. Click it again to drop it and resume.
- **Hold the record** to stop it, exactly like putting a hand on a spinning
  disc. Playback resumes when you let go.
- **Turn the record while holding it** to scrub. The playback position follows
  the rotation at the real ratio — one full turn is 1.8 s of audio at 33⅓ RPM
  — so you can rock it back and forth to hunt for a spot.
- **Drag the window background** to move it. There is no title bar.
- **Hover** anywhere over the window for play/pause and skip, below the track
  name. They fade rather than appear, so nothing above them shifts.
- **Right-click** for always-on-top, track info, the glass background, online
  artwork lookup, and turntable speed (33⅓ / 45 / 78 RPM — 33⅓ is the real
  speed, and it is fast).
- **Glass Background** swaps the transparent window for a slow field of
  colour pulled from the current cover, under a frosted pane. Off by default.
- **Quit** with ⌘Q, or from the right-click menu. The close button is hidden.
- Drag a window corner to resize; the record scales with it.

## How it works

| Piece | What it does |
| --- | --- |
| `MusicBridge.swift` | Apple events to Music.app: track info, artwork, transport |
| `CatalogArtwork.swift` | Online cover lookup, used only when Music has none |
| `Palette.swift` | Pulls representative colours out of the cover art |
| `GlassBackground.swift` | The animated colour field behind the record |
| `NowPlayingModel.swift` | Polls state, derives rotation angle from wall-clock time |
| `VinylView.swift` | Draws the disc, grooves, label, and tonearm |
| `ContentView.swift` | Layout, hover controls, window chrome removal |

Track changes arrive instantly over Music's `com.apple.Music.playerInfo`
distributed notification; a 1–2.5 s poll keeps the playback position (and so
the tonearm) in sync.

Rotation is computed from elapsed wall-clock time rather than accumulated per
frame, so pausing freezes the label exactly where it was and dropped frames
never make the record drift.

### Direct manipulation, and what it can't do

Grabbing the record pauses Music and turns the disc by hand, mapping rotation
onto `player position`. Measured round-trips to Music: `pause` 17–22 ms,
`play` ~84 ms, a seek ~37 ms — about 27 position updates a second, which is
enough for the record to track your hand.

**It is not real scratching, and it cannot be.** A turntablist's scratch is
the record's own audio played back at a varying rate and direction. Nothing
here has access to Music's audio stream — the app can only ask Music to jump
to a timestamp. So dragging repositions the song; it does not pitch-bend or
reverse it. Music stays paused while you hold the record, which is why
scrubbing is silent rather than a stutter of half-buffered fragments.

Two behaviours of Music.app shaped this code, both measured:

- **Its state lags its commands.** 400 ms after a `pause` was acknowledged,
  `player state` still read `playing`, then flipped 67 ms later. So an
  acknowledgement is not proof; the model holds an *expected* state and
  ignores snapshots that disagree until one confirms or 1.5 s passes.
- **Its notifications can drown the seeks.** Every seek makes Music post
  `playerInfo`, and each of those queued a snapshot read on the same serial
  Apple-event queue, backing seeks up by ~700 ms. Polling is suspended for
  the duration of a drag.

Seeks are coalesced — one in flight, always the newest target — so a fast
drag never queues stale positions behind itself.

### The glass background

Colours come from a 40×40 downsample of the cover, binned into a coarse RGB
grid and scored by area weighted toward saturation, so a large beige wall
doesn't beat the actual accent. Picks are kept apart in hue so the result
isn't five shades of one colour.

Album art skews dark, and a background built straight from those values comes
out near-black — the first attempt was almost invisible. Each tint is lifted
to a usable brightness and its saturation reined in, keeping only the hue.

The frosted pane is hand-rolled rather than `.ultraThinMaterial`: the window
is transparent, so a system material samples the desktop behind it and the
look changes with the wallpaper. The field runs at 24fps — it is scenery, and
a heavily blurred layer at 60fps is a waste of the GPU.

### Where the album art comes from

Two sources, in order:

1. **Music.app itself**, over AppleScript. Works for anything in your library.
   No network.
2. **Apple's public iTunes Search API**, only if step 1 came back empty.

Step 2 exists because Apple Music **streaming** tracks — `class of current
track` is `URL track` — expose no artwork at all. `count of artworks` stays 0
for the entire song, so there is nothing local to read.

The obvious alternative, the private MediaRemote framework that the system's
own now-playing UI uses, does not work here: since macOS 15.4 it answers only
Apple-signed binaries. Measured on macOS 26.5, an ad-hoc-signed binary gets a
**0-key dictionary in 5 ms**, while the identical call from the Apple-signed
`swift` interpreter returns the full payload including artwork. It was
implemented, confirmed dead, and removed.

The lookup sends the artist and album of the playing track to
`itunes.apple.com`. It is unauthenticated, uses an ephemeral URL session with
cookies disabled, caches per track so a song is looked up once, and requires
the title or artist to match before a cover is accepted — a wrong cover is
worse than none. Turn it off with **Look Up Artwork Online** in the
right-click menu and the app never touches the network; streaming tracks then
show a printed label with the title and artist instead.

## Development helpers

The binary has two flags used while building the artwork, so the record can be
checked without launching a window:

```bash
./build.sh
"build/Music Vinyl.app/Contents/MacOS/MusicVinyl" --dump-state
```

- `--dump-state` — print what Music currently reports, which artwork source
  answered, and how long the online lookup took, then exit.
- `--render-preview out.png` — render the record offscreen to a PNG.
  `PREVIEW_ANGLE`, `PREVIEW_PROGRESS`, `PREVIEW_NOART=1`, `PREVIEW_ARM=off`,
  `PREVIEW_ART=cover.jpg`, and `PREVIEW_GLASS=1` control the frame.
- `--selftest` — drive the tonearm and scrub handlers against a live Music.app
  and report pass/fail, then restore the playback state it started with. The
  gestures need a mouse to exercise otherwise. `VINYL_TRACE=1` adds a
  transition log, which is how both Music quirks above were found.

Note for anyone extending `MusicBridge`: never block the main thread waiting on
its serial queue. `NSAppleScript` needs the main run loop to deliver its Apple
Event reply, so a `queue.sync` from the main thread deadlocks — verified with a
stack sample. Use the async API, or `Pump` if you need to wait.

`./make-icon.sh` regenerates `Resources/AppIcon.icns` from the same SwiftUI
code that draws the record.

## Requirements

macOS 14+, Swift 6 toolchain (Xcode 15+). No third-party dependencies.
