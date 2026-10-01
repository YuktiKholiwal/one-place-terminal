#!/bin/sh
# Records Claude Code session state for OnePlaceTerminal.
#
# Invoked by Claude Code hooks with the event name as $1 and the hook JSON on
# stdin. Writes one small file per session; OnePlaceTerminal reads the directory
# on each scan. No socket, no daemon, survives the app restarting.
#
# $PPID is the `claude` process that spawned this hook. The app resolves it to a
# terminal session by walking the process tree, which disambiguates the case
# where several sessions share one working directory.

set -u
STATE_DIR="${HOME}/Library/Application Support/OnePlaceTerminal/state"
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

EVENT="${1:-unknown}"
JSON=$(cat 2>/dev/null || true)
CWD=$(printf '%s' "$JSON" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
SID=$(printf '%s' "$JSON" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)

printf '%s\n%s\n%s\n%s\n%s\n' "$EVENT" "$PPID" "${CWD:-}" "$(date +%s)" "${SID:-}" \
  > "$STATE_DIR/$PPID" 2>/dev/null || true
exit 0
