#!/usr/bin/env bash
# Symlinks everything here into ~/.config. Anything already there is moved to <name>.bak-<timestamp>.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
stamp="$(date +%Y%m%d-%H%M%S)"

link() {
    local src="$here/$1" dst="$HOME/.config/$1"
    mkdir -p "$(dirname "$dst")"
    if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
        echo "ok      $dst"; return
    fi
    if [ -e "$dst" ] || [ -L "$dst" ]; then
        mv "$dst" "$dst.bak-$stamp"; echo "backup  $dst -> $dst.bak-$stamp"
    fi
    ln -s "$src" "$dst"; echo "linked  $dst"
}

link quickshell/wavegoo
link quickshell/goonotes
link quickshell/hourglass
link quickshell/visits
link alacritty/alacritty.toml
link autostart/wavegoo.desktop
link autostart/visits.desktop
echo "done. run: qs -c wavegoo"
