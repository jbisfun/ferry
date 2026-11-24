#!/bin/sh
# Register ferry-gui with the desktop (launcher entry + icon) for this user.
#   tools/install-desktop.sh [PREFIX]   (PREFIX defaults to ./zig-out)
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
prefix=$(cd "${1:-$root/zig-out}" && pwd)
id=io.github.jbisfun.Ferry
data=${XDG_DATA_HOME:-$HOME/.local/share}
install -Dm644 "$root/assets/ferry.png" "$data/icons/hicolor/512x512/apps/$id.png"
install -Dm644 "$root/assets/ferry-128.png" "$data/icons/hicolor/128x128/apps/$id.png"
mkdir -p "$data/applications"
cat > "$data/applications/$id.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Ferry
Comment=Sign and install iOS apps
Comment[zh_TW]=簽署並安裝 iOS App
Exec=$prefix/bin/ferry-gui
Icon=$id
Terminal=false
Categories=Development;Utility;
StartupWMClass=$id
EOF
command -v update-desktop-database >/dev/null && update-desktop-database "$data/applications" || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "$data/icons/hicolor" || true
echo "installed $data/applications/$id.desktop"
