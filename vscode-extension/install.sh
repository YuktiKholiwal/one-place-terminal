#!/bin/bash
# Installs the focus helper into VS Code. Reload VS Code afterwards
# (Cmd+Shift+P -> "Developer: Reload Window") for it to start.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.vscode/extensions/local.oneplace-terminal-focus-1.0.0"
rm -rf "$DEST"; mkdir -p "$DEST"
cp "$SRC/package.json" "$SRC/extension.js" "$DEST/"
echo "installed to $DEST"
echo "Reload VS Code (Cmd+Shift+P -> Developer: Reload Window) to activate."
