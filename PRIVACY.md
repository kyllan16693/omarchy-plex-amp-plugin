# Privacy notice

Ampbar for Plex does not operate a service, include analytics, or send data to
the plugin author or the Omarchy marketplace.

When you sign in, the plugin communicates with `plex.tv` and `app.plex.tv` to
complete Plex's PIN sign-in flow and discover servers associated with your
account. It then communicates directly with the Plex Media Server you choose
to browse metadata, report playback progress, and stream music. Plex's own
privacy policy and terms govern those services.

Automatic discovery prefers a local, non-relay HTTPS connection where Plex
offers one, and can fall back to HTTP. With an `http://` server address, your Plex token
and media requests travel to that address without HTTPS transport encryption;
only do that on a network you trust.

The plugin stores Plex account/server tokens and a client identifier in
`~/.config/omarchy/plexamp/` with mode `0600`. Playback preferences, queue
rating keys, and waveform caches live in `~/.local/state/omarchy/plexamp/`,
a mode-`0700` directory. Full stream and artwork URLs are not written to
state. A stream URL can contain a Plex token; it is retained only in the live
player, passed to waveform analysis through a mode-`0600` temporary curl
config, and removed as soon as that request ends. The audio fetched for
analysis is held in a mode-`0600` temporary file in the same directory and
deleted once the waveform is built. Artwork URLs carry the token too, as Plex
requires; covers are fetched through the same size- and time-bounded requests
as library data and handed to the image loader as in-memory image data, so the
URL never reaches Quickshell's image loader or its log. The mpv IPC socket
lives in the per-user runtime directory (`$XDG_RUNTIME_DIR`, mode `0700`). Authentication tokens reach curl and jq through stdin, without
appearing in process arguments or exported environment variables.
Sign-in and server-discovery requests, which carry the token in a header,
do not follow redirects. The waveform download follows at most three
redirects, to http or https only; its token is part of the original URL and
is not added to a redirect target.

Disabling or removing the plugin stops the supervised player. Removing the
plugin does not delete credentials or state automatically. Sign
out before removal to delete `auth.json`, and remove the two directories above
yourself if you want to erase all local plugin data.
