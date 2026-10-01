#!/bin/bash
# Restores the terminal sessions recorded in the last snapshot.
#
#   ./restore.sh              show what would be restored
#   ./restore.sh --run        recreate them as VS Code terminals
#   ./restore.sh --print      print the raw commands, to paste anywhere
#   ./restore.sh --history    list earlier snapshots
#   ./restore.sh --from FILE  use a specific snapshot
set -euo pipefail

SUPPORT="$HOME/Library/Application Support/OnePlaceTerminal"
SNAP="$SUPPORT/snapshot.json"
MODE="${1:-show}"
[ "$MODE" = "--from" ] && { SNAP="$2"; MODE="${3:-show}"; }

if [ "$MODE" = "--history" ]; then
  echo "Snapshots in $SUPPORT/history:"
  ls -1t "$SUPPORT/history" 2>/dev/null | head -30 | sed 's/^/  /' || echo "  none yet"
  exit 0
fi

[ -f "$SNAP" ] || { echo "No snapshot yet at $SNAP"; echo "Start OnePlaceTerminal.app and let it see your sessions."; exit 1; }

python3 - "$SNAP" "$MODE" <<'PY'
import json, sys, os, subprocess
snap, mode = sys.argv[1], sys.argv[2]
d = json.load(open(snap))
rows = d["sessions"]

if mode == "--print":
    for s in rows:
        cmd = s.get("restore")
        print(f'cd {s["cwd"]!r}' + (f' && {cmd}' if cmd else ''))
    sys.exit(0)

print(f'Snapshot from {d["savedAt"]}  —  {len(rows)} sessions\n')
w = max((len(s["project"]) for s in rows), default=8)
a = max((len(s.get("agent") or "") for s in rows), default=6)
for s in rows:
    tag = s.get("sessionID")
    tag = tag[:8] if tag else (s.get("restore") or "shell")
    print(f'  {s["project"]:<{w}}  {(s.get("agent") or "-"):<{a}}  {tag:<22}  '
          f'{s["cwd"].replace(os.path.expanduser("~"),"~")}')

if mode != "--run":
    print(f'\n{len(rows)} sessions. Run with --run to recreate them in VS Code,')
    print('or --print to get the raw commands.')
    sys.exit(0)

# Hand the work to the VS Code extension, which owns the terminals.
socks = []
fd = os.path.join(os.path.dirname(snap), "focus")
if os.path.isdir(fd):
    socks = [os.path.join(fd, f) for f in os.listdir(fd) if f.endswith(".sock")]
if not socks:
    print('\nVS Code extension not running. Install it with')
    print('  ./vscode-extension/install.sh   (then reload VS Code)')
    print('or use --print and paste the commands yourself.')
    sys.exit(1)

import socket
for path in socks:
    try:
        c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); c.settimeout(10)
        c.connect(path); c.sendall(b"restore\n")
        reply = c.recv(64).decode().strip(); c.close()
        if reply.startswith("restored"):
            print(f'\nRestored into VS Code: {reply}')
            sys.exit(0)
    except Exception:
        continue
print('\nCould not reach the VS Code extension. Try --print.')
sys.exit(1)
PY
