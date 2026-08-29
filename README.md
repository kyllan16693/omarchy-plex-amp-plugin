# Plexamp for Omarchy

A Plex music player that lives in the Omarchy bar. The cover of whatever is
loaded sits in the bar, dimming while paused; pressing it (or a keybind) drops
down a keyboard-driven panel with cover art, a waveform scrubber, transport
controls, and three tabs — Home, Radio and Search.

The panel takes on the colours of whatever is playing, using the same
four-corner album palette (`UltraBlurColors`) the Plexamp app paints with, and
clicking the cover art swaps to a mini viewer: art as large as it goes, plus
seek and skip.

The plugin *is* the player — it talks to the Plex API for your library and stream
URLs, then plays them through a headless `mpv` it controls over an IPC socket.
Plexamp itself is not required or used.

## Requirements

- Omarchy 4 (`omarchy-shell`)
- `mpv`, `ffmpeg`, `curl`, `jq`, `python3`, `bash`
- A Plex account with a music library

## Install

```sh
./install.sh
```

That copies the plugin to `~/.config/omarchy/plugins/io.github.kyllan.plexamp/`,
validates it, rescans, and enables it. Add the **Plexamp** widget to your bar from
the bar settings if it doesn't appear on its own.

## Sign in

Open the dropdown and press `s`. The plugin asks plex.tv for a link code, opens
your browser at plex.tv, and shows the code in the panel. Enter it, and the
plugin finds your servers, picks the best reachable connection, and starts
loading your library.

Credentials are written by `bin/plexamp-auth` to
`~/.config/omarchy/plexamp/auth.json` with mode `0600`. Nothing is written from
QML, and the token never leaves your machine except to talk to Plex.

Sign out with `O` (capital) in the panel, or:

```sh
~/.config/omarchy/plugins/io.github.kyllan.plexamp/bin/plexamp-auth logout
```

If your server moves (new IP, relay churn), re-probe connections with:

```sh
~/.config/omarchy/plugins/io.github.kyllan.plexamp/bin/plexamp-auth rediscover
```

## Keys

Inside the dropdown:

| Key | Action |
| --- | --- |
| `j` / `k` / `↓` / `↑` | Move the cursor |
| `l` / `→` | Open what's under the cursor (album / artist) |
| `h` / `←` | Back out one level — browse view, tab, or the mini viewer |
| `Enter` | Play what's under the cursor |
| `Space` | Play / pause — everywhere, including the mini viewer |
| `Tab` / `Shift+Tab` | Switch tab |
| `1` / `2` / `3` | Home / Radio / Search |
| `/` | Jump to the search box |
| `v` | Mini viewer (big art, minimal controls) |
| `p` | Play / pause (same as `Space`) |
| `n` / `b` | Next / previous track |
| `,` / `.` | Seek 5s back / forward |
| `<` / `>` | Seek 30s back / forward |
| `+` / `-` | Volume up / down |
| `m` | Mute |
| `a` | Browse more from the current artist |
| `d` | Browse the current album |
| `R` | Start radio from the current artist |
| `L` | Switch music library (when the server has more than one) |
| `x` / `Backspace` | Like `h`, but closes the panel once there's nothing left to leave |
| `g` / `G` | Jump to top / bottom of the list |
| `r` | Reload the library |
| `s` | Sign in (when signed out) |
| `O` | Sign out |
| `Esc` | Close |

In the search box, `Enter` runs the search and moves focus to the results, `↓`
does the same without waiting, and `Esc` steps back to the list.

`Tab` wraps around the three tabs in both directions, from inside the search box
too.

Every key means the same thing in the mini viewer as it does in the full panel:
`h` leaves it, `,` / `.` seek, `Space` toggles play, `n` / `b` skip. Reaching for
the library — a tab key, `/`, `a`, `d`, `r`, `L` — drops you back into the full
panel on its own.

The radio button dims when there's nothing to seed a station from — no artist on
the current track, and no library station to fall back on.

Mouse: left-click the bar icon toggles the panel, right-click plays/pauses,
middle-click skips. In the list, left-click plays and right-click opens. Click
the cover art for the mini viewer, and click anywhere on the waveform to seek.

## Global keybinds

The plugin exposes IPC methods you can bind anywhere in Hyprland:

```sh
omarchy-shell io.github.kyllan.plexamp toggle
omarchy-shell io.github.kyllan.plexamp playPause
omarchy-shell io.github.kyllan.plexamp next
omarchy-shell io.github.kyllan.plexamp previous
omarchy-shell io.github.kyllan.plexamp volumeUp
omarchy-shell io.github.kyllan.plexamp volumeDown
omarchy-shell io.github.kyllan.plexamp radio
omarchy-shell io.github.kyllan.plexamp mini
omarchy-shell io.github.kyllan.plexamp status
```

`omarchy-shell <target> <method>` addresses the plugin's own IPC handler. The
`omarchy-shell shell toggle <id> '{}'` form works too, but only for `toggle`.

`install.sh` does not touch your Hyprland config. These are the bindings this
plugin was set up with — add them to `~/.config/hypr/bindings.lua` yourself:

```lua
o.bind("SUPER + M", "Plexamp", "omarchy-shell io.github.kyllan.plexamp toggle")
o.bind("SUPER + ALT + P", "Plexamp play/pause", "omarchy-shell io.github.kyllan.plexamp playPause")
o.bind("SUPER + ALT + N", "Plexamp next track", "omarchy-shell io.github.kyllan.plexamp next")
o.bind("SUPER + ALT + B", "Plexamp previous track", "omarchy-shell io.github.kyllan.plexamp previous")
```

The `XF86Audio*` media keys are deliberately left alone: Omarchy already routes
them to MPRIS, and taking them would break media control in your browser.

## Settings

Available from the bar widget settings:

- **Hide the widget when nothing is playing** — off by default, so the widget is
  always there as a launcher.
- **Show the album cover in the bar while a track is loaded** — on by default.
  Turn it off to go back to the animated sound bars.
- **History entries to load** — how deep the Home tab's history list goes.

Volume and the chosen music library are remembered in
`~/.local/state/omarchy/plexamp/state.json`.

## Tabs

- **Home** — recent plays, recently added, and your listening history.
- **Radio** — the stations Plex generates for the library, plus a station seeded
  from whatever is playing.
- **Search** — artists, albums and tracks, searched as you type.

Selecting an artist gives you their albums first, then singles & EPs, then
anything else they turn up on.

## Gapless

mpv is kept holding a two-entry playlist: whatever is playing, plus the track
after it. With `--prefetch-playlist` mpv opens and buffers that second stream
while the first is still going, so a track change is a playlist step rather than
a fresh network open — and pressing `n` skips through the same prefetched entry.
`playlist-pos` is what tells the plugin the change happened; a guard timer falls
back to loading the track the ordinary way if mpv never moves.

The next track's waveform is analysed on the same schedule, so the timeline is
drawn the moment the track starts instead of a second into it.

## The waveform

Your server exposes no loudness ramps (that needs Plex's own sonic analysis), so
`bin/plexamp-waveform` builds the envelope itself: it decodes the track with
`ffmpeg` at a low sample rate and reduces it to 120 RMS buckets. A four-minute
FLAC takes well under a second over a LAN, it runs at `nice 19` after playback
has already started, and every result is cached by rating key under
`~/.local/state/omarchy/plexamp/waveform/` and again in memory, so a track is
analysed once and never again. Tracks it can't read fall back to a plain progress line.

## Layout

| File | Role |
| --- | --- |
| `manifest.json` | Plugin manifest (`service` + `bar-widget`) |
| `Service.qml` | Plex session, library queries, play queue, mpv IPC |
| `Panel.qml` | Bar button and the keyboard-driven dropdown |
| `PlexApi.js` | Pure URL-building and response-parsing helpers |
| `PlexPanel.qml` | Vendored `Ui/KeyboardPanel` with a tintable card background |
| `SeekBar.qml` | Elapsed / waveform / remaining, with a plain-bar fallback |
| `Waveform.qml` | The mirrored envelope itself, drawn on two clipped canvases |
| `PlexIcon.qml` | The Plex chevron, drawn to match the bar foreground |
| `SoundBars.qml` | Animated playing indicator, and the bar's art fallback |
| `bin/plexamp-auth` | plex.tv PIN sign-in and server discovery |
| `bin/plexamp-waveform` | ffmpeg loudness envelope, cached per track |

`PlexPanel.qml` is a copy of Omarchy's `Ui/KeyboardPanel` with one change — the
card's fill is a property instead of a hard-coded theme colour, which is what
lets the album palette reach the panel's edges. Re-sync it if that file changes
upstream.
