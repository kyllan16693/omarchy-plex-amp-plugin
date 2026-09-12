#!/usr/bin/env bash
# Install (or reinstall) the Ampbar for Plex plugin into the Omarchy plugin directory.
#
# Files are copied rather than symlinked: omarchy-plugin-validate rejects any
# symlink inside a plugin folder, so a symlinked dev checkout would never load.

set -euo pipefail

PLUGIN_ID="io.github.kyllan.ampbar"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$PLUGIN_ID"

# The only destructive operation below is constrained to this plugin's own
# directory. Keep that invariant explicit if this script is ever refactored.
case "$DEST" in
  */omarchy/plugins/"$PLUGIN_ID") ;;
  *)
    echo "refusing unsafe plugin destination: $DEST" >&2
    exit 2
    ;;
esac

echo "==> Installing $PLUGIN_ID"
echo "    from $SRC"
echo "    to   $DEST"

# Stage into a sibling directory and swap it in. Copying file-by-file into the
# live plugin folder makes the shell's watcher fire a reload per file, and it
# has been seen to crash mid-reload under that storm. The dot prefix keeps the
# staging directory out of the plugin scan while it fills up.
mkdir -p "$(dirname "$DEST")"
STAGE="$(mktemp -d "$(dirname "$DEST")/.$PLUGIN_ID.installing.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
chmod 755 "$STAGE"

# Only ship what the shell needs. Anything not listed here stays in the repo.
cp "$SRC/manifest.json" "$SRC"/*.qml "$SRC"/*.js "$SRC/preview.png" \
  "$SRC/README.md" "$SRC/LICENSE" "$SRC/COPYRIGHT" \
  "$SRC/THIRD_PARTY_NOTICES.md" "$SRC/PRIVACY.md" "$STAGE/"
mkdir -p "$STAGE/assets"
cp -R "$SRC/assets/screenshots" "$STAGE/assets/"
mkdir -p "$STAGE/bin"
cp "$SRC"/bin/* "$STAGE/bin/"
chmod +x "$STAGE"/bin/*

if command -v omarchy >/dev/null 2>&1; then
  echo "==> Validating"
  omarchy plugin validate "$STAGE"
fi

rm -rf "$DEST"
mv "$STAGE" "$DEST"
trap - EXIT

if command -v omarchy-shell >/dev/null 2>&1; then
  echo "==> Rescanning plugins"
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
fi

if command -v omarchy >/dev/null 2>&1; then
  echo "==> Enabling"
  omarchy plugin enable "$PLUGIN_ID" || true
fi

echo
echo "Done. Add the widget from the bar settings if it isn't visible yet,"
echo "then open it and press 's' to sign in to Plex."
