# Privacy notice

Ampbar for Plex does not operate a service, include analytics, or send data to
the plugin author or the Omarchy marketplace.

When you sign in, the plugin communicates with `plex.tv` and `app.plex.tv` to
complete Plex's PIN sign-in flow and discover servers associated with your
account. It then communicates directly with the Plex Media Server you choose
to browse metadata, report playback progress, and stream music. Plex's own
privacy policy and terms govern those services.

Automatic discovery prefers a local, non-relay HTTPS connection where Plex
offers one. If you manually enter an `http://` server address, your Plex token
and media requests travel to that address without HTTPS transport encryption;
only do that on a network you trust.

The plugin stores Plex account/server tokens and a client identifier in
`~/.config/omarchy/plexamp/` with mode `0600`. Playback preferences, queue
metadata, and waveform caches live in `~/.local/state/omarchy/plexamp/`.
Streaming URLs may contain a Plex token; they are passed only to the local mpv
process and its per-user IPC socket under `$XDG_RUNTIME_DIR`.

Removing the plugin does not delete credentials or state automatically. Sign
out before removal to delete `auth.json`, and remove the two directories above
yourself if you want to erase all local plugin data.
