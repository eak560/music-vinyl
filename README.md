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
- **Disc style** in Turntable settings: classic vinyl with the cover as a
  centre label, a picture disc where the cover fills the whole record, or a
  clear pressing you can see the cover through.
- **Speed** is a continuous slider from 5 to 120 RPM, with 33⅓ / 45 / 78
  presets. It drives the scrub ratio too, so a turn of the record always
  moves the song by one revolution's worth of audio.
- **Transport** is a cassette deck's: cream keys in a dark housing that
  travel when pressed, with the glyphs drawn as shapes rather than set in a
  symbol font.
- **Right-click** for always-on-top, track info, the glass background, online
  artwork lookup, and turntable speed (33⅓ / 45 / 78 RPM — 33⅓ is the real
  speed, and it is fast).
- **Glass Background** swaps the transparent window for a slow field of
  colour pulled from the current cover, under a frosted pane. Off by default.
- **Playlists** from the hover controls or the right-click menu. The list
  responds to the cursor: labels slide out, warm toward the accent colour, and
  the rule beside each one lengthens as you approach it. The accent is taken
  from the current cover, so the browser belongs to whatever is playing.
- **Tracks** appear on a selector wheel curved around the left edge — the
  entry in the middle is sharp and bright, its neighbours fade and blur as
  they curl away. Scroll, drag or click to turn it; clicking plays. Whenever
  the panel is wide enough, the cover of whatever the wheel is passing over
  sits alongside it and cross-fades as you go. Next and previous then move
  through that list, and the playlist a song is playing from is shown under
  the artist.
- **Full screen** with ⌃⌘F, or from the right-click menu. The record scales
  up, the glass background squares off its corners, and always-on-top steps
  aside for the duration.
- **Quit** with ⌘Q, or from the right-click menu. The close button is hidden.
- Drag a window corner to resize; the record scales with it.

## How it works

| Piece | What it does |
| --- | --- |
| `MusicBridge.swift` | Apple events to Music.app: track info, artwork, transport |
| `CatalogArtwork.swift` | Online cover lookup for streaming tracks |
| `PlaylistLibrary.swift` | Reads playlists and their tracks out of Music |
| `PlaylistPanel.swift` | The playlist browser |
| `LineSidebarList.swift` | Playlists, with the cursor-proximity rules |
| `OptionWheelList.swift` | Tracks, on a curved selector wheel |
| `RetroTransport.swift` | Cassette-deck transport keys |
| `SettingsPanel.swift` | Disc style, speed, and window toggles |
| `DiscStyle.swift` | Which of the three records is drawn |
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

The fluid feel comes from three things layered together: each colour is drawn
as two lobes on mismatched orbits, so they merge and pull apart instead of
sliding as one rigid blob; the whole field turns very slowly; and the wave
bands are domain-warped — their phase modulated by a second, slower wave —
which breaks up the regularity that gives a plain sine away. Every period is
incommensurate with the others, so the motion never visibly loops.

The frosted pane is hand-rolled rather than `.ultraThinMaterial`: the window
is transparent, so a system material samples the desktop behind it and the
look changes with the wallpaper. The field runs at 30fps — it is scenery, and
a heavily blurred layer at 60fps is a waste of the GPU.

In full screen the record is height-limited, so the stack ends up only as
wide as the disc — roughly 860pt on a 1512pt display. `.background` covers
exactly the view it is attached to, so the colour field painted that column
and left the rest of the screen bare; the container fills the window first.

Full screen took two fixes. The window needs `.fullScreenPrimary` in its
collection behaviour — `.fullScreenAuxiliary`, which it had, only lets it ride
along in another app's space and can't give it one of its own. But SwiftUI
also marks the window `.fullScreenNone`, which is *mutually exclusive* with
`.fullScreenPrimary`: inserting primary while none is still set is silently
rejected, and `toggleFullScreen(nil)` then does nothing at all, with no error.
SwiftUI reapplies it after the `NSViewRepresentable` has run, so clearing it
once at setup is not enough — it is cleared again immediately before each
toggle.

### Keeping the label seamless across track changes

Clearing the cover the moment the track changes puts the printed fallback on
screen for as long as the lookup takes — up to a second on a streaming track —
which reads as a flicker. Four things remove it:

- The previous cover stays on the label until the new one resolves, or until
  every source has come back empty. Nothing blank in between.
- The swap cross-fades over 1.1s on a smoothstep curve — long and gentle
  enough to register as the label settling rather than as a cut.
- Covers are memoised per **album**, not per track, so walking through a
  record fetches once and every track after it is free.
- That cache is also written to disk, so a cover is fetched once ever rather
  than once per launch.

Measured: 387 ms cold, **11 ms** from the disk cache, **8 ms** for a different
track from an album already seen.

The blend is driven from the clock, not from a SwiftUI animation. The label
lives inside a `TimelineView` that rebuilds every frame to spin the record,
and that rebuilding disrupts transitions — an `.animation` with `.transition`
on the image simply cut instead of fading. Instead the model records when the
cover changed, the view derives the blend from elapsed time, and both faces
are drawn at once: outgoing underneath, incoming over it at that opacity.
That covers cover-to-cover, cover-to-printed-label and back with one path.
The timeline keeps running through a blend even when playback is stopped, or
it would freeze part-way.

### Why the app keeps its own queue

Playing a single track out of a playlist leaves Music unable to move on:
`next track` and `back track` return without error and do nothing. Directly
after such a play, `name of current playlist` fails outright with -1728; on
other playlists Music *does* report a playlist name and still refuses to
advance, so its having one proves nothing. Referencing the playlist by name,
as a `user playlist`, revealing the track first, and playing the playlist
before the track were all tried — every form that plays a track object drops
the context, and `play theList` followed by skipping is unreliable because the
skips fire before playback has started.

So picking a track from the browser records the playlist and the index, and
next/previous move within that. Playing a *whole* playlist gives Music a real
context and drops the stand-in.

One thing this does not do: **a track picked from the browser stops at the end
rather than continuing the list.** Advancing automatically on a `stopped`
snapshot was implemented and removed — Music also reports `stopped` briefly
*during* a track change, which is indistinguishable from reaching the end, so
each advance triggered the next and the queue galloped from track 3 to 9 on
its own. Use the whole-playlist play button for continuous listening.

### The two browser lists

Both are SwiftUI reworkings of React components (React Bits' `LineSidebar` and
`OptionWheel`), so the behaviour is reimplemented rather than ported.

The sidebar reads the pointer once for the whole list with
`onContinuousHover` and derives each row's proximity arithmetically from its
index — a fixed row height and gap mean no `GeometryReader` per row. Proximity
runs through the same smoothstep curve as the original and drives the shift,
the colour blend, the rule length and the tick length together.

The wheel places entries on a circle whose radius keeps the arc between
neighbours exactly one row tall, so the tilt angle controls how tightly it
curls. Only entries within seven steps of the middle are built; past that they
are transparent anyway, and a several-hundred-track playlist would otherwise
lay out every row.

SwiftUI has no scroll-wheel modifier on macOS. An `NSView` behind the wheel
overriding `scrollWheel` was tried first and never fired — a view placed
behind SwiftUI content does not win the hit test, so the events went to the
content instead. A local `NSEvent` monitor sees them regardless of the view
hierarchy, and the panel covers the window while it is open, so consuming
them is safe.

In full screen the panel is capped rather than stretched to the display:
filling a 1512pt screen with a list left it mostly empty.

### Media keys

The keyboard's ⏭ / ⏮ keys talk to Music directly, so they hit exactly the
limitation above: a track picked from the browser is not something Music can
advance past, and the keys appear dead while play/pause still works.

**Use Media Keys** (Turntable settings, on by default) installs a
`CGEventTap` on system-defined events and routes those two keys to the app's
queue. It only swallows a key while the queue is active — the rest of the
time, and always for play/pause, the event passes straight through to Music.

It needs **Accessibility** permission (System Settings → Privacy & Security →
Accessibility). Without it the tap refuses to install and the keys behave as
before. Note the app is ad-hoc signed, so its identity changes every time you
rebuild: after `./build.sh` you may have to remove and re-add it in that list.

### Where the album art comes from

Two sources, and which one leads depends on the track:

- **Library tracks** ask Music.app over AppleScript. Its artwork is
  authoritative for these, and costs no network.
- **Streaming tracks** (`class of current track` is `URL track`) go to
  Apple's public iTunes Search API first, falling back to Music.

Music cannot be trusted for streaming artwork, in two distinct ways. For some
tracks it reports none at all — `count of artworks` stays 0 for the whole
song. For others it returns a cover from an entirely different release: on
*Puddles* from **Melt**, `artwork 1 of current track` handed back the sleeve
of another single by the same artist, at a confident 800×800. There is no way
to tell a good one from a bad one locally, so the catalogue — whose result can
be checked against the track's own title — leads for streaming.

The obvious alternative, the private MediaRemote framework that the system's
own now-playing UI uses, does not work here: since macOS 15.4 it answers only
Apple-signed binaries. Measured on macOS 26.5, an ad-hoc-signed binary gets a
**0-key dictionary in 5 ms**, while the identical call from the Apple-signed
`swift` interpreter returns the full payload including artwork. It was
implemented, confirmed dead, and removed.

The lookup runs in two passes. First the track itself. If that finds nothing,
the album — because Apple's search index does not surface every song: a search
for "Daniel Caesar Japanese Denim" returns instrumental covers by other
artists and not the track itself, at any result limit. Its album is indexed
though, and an album cover is what Music displays anyway.

The lookup sends the artist and album of the playing track to
`itunes.apple.com`. It is unauthenticated, uses an ephemeral URL session with
cookies disabled, and caches per track so a song is looked up once. A result
is accepted only if its **title** matches, after normalising away case,
accents, and qualifiers like "(Radio Edit)" or "- Single", and only with
corroboration from the artist or album. Matching on artist alone would
cheerfully accept a different song by the same act — a wrong cover is worse
than none. Turn it off with **Look Up Artwork Online** in the
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
  `PREVIEW_ART=cover.jpg`, `PREVIEW_GLASS=1`, `PREVIEW_DISC=picture|glass`,
  and `PREVIEW_ART2` +
  `PREVIEW_FADE=0.5` (to see the cover blend mid-way) control the frame.
- `--render-layout out.png` — render the window layout at `PREVIEW_SIZE=WxH`.
  Used to check that the background fills a wide window rather than just the
  record's column.
- `VINYL_FULLSCREEN_TEST=1` — on launch, toggle full screen after 2s, log
  whether the window actually entered it, and exit. The menu item cannot be
  clicked from a script, and this is what caught the `.fullScreenNone` flag.
- `--lookup "<title>" "<artist>" "<album>"` — run the artwork search for a
  track that isn't playing. `DUMP_ARTWORK=path` writes the cover it found.
- `--playlists` — list playlists and the tracks of the first one.
- `--render-playlists out.png` — render the playlist panel with the real
  library. `PREVIEW_TRACKS=1` opens a playlist.
- `--render-chrome out.png` — render the transport keys and settings panel.
- `VINYL_NO_SCROLL=1` — lay panels out flat for the renders above.
  `ImageRenderer` does not materialise `ScrollView` content, and renders
  AppKit-backed controls (`Picker`, `Slider`, `Toggle`) as yellow
  placeholders. Both are the renderer, not the views.
- `--queue-test` — pick a track out of a playlist the way the browser does,
  then check that next and previous still move.
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
