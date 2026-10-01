#!/bin/bash
# Adds OnePlaceTerminal's hooks to ~/.claude/settings.json.
#
# This is opt-in and global: it affects every Claude Code session you run.
# Without it the app still works — you just don't get the "waiting on you"
# signal, because the process table cannot distinguish a Claude that is
# thinking from one that is waiting for your reply.
#
# Run with --uninstall to remove them again.
set -euo pipefail

SETTINGS="$HOME/.claude/settings.json"
SUPPORT="$HOME/Library/Application Support/OnePlaceTerminal"
HOOK="$SUPPORT/oneplace-hook.sh"
SRC="$(cd "$(dirname "$0")" && pwd)/oneplace-hook.sh"

mkdir -p "$SUPPORT" "$HOME/.claude"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SRC" "$HOOK" && chmod +x "$HOOK"

cp "$SETTINGS" "$SETTINGS.oneplace-backup.$(date +%s)"

MODE="${1:-install}"
python3 - "$SETTINGS" "$HOOK" "$MODE" <<'PY'
import json, sys, collections
settings_path, hook, mode = sys.argv[1], sys.argv[2], sys.argv[3]
with open(settings_path) as f:
    try: cfg = json.load(f, object_pairs_hook=collections.OrderedDict)
    except json.JSONDecodeError: cfg = collections.OrderedDict()

hooks = cfg.setdefault("hooks", collections.OrderedDict())
MARK = "oneplace-hook.sh"

# Strip any previous install so this is idempotent.
for event in list(hooks):
    kept = []
    for matcher in hooks.get(event) or []:
        inner = [h for h in (matcher.get("hooks") or []) if MARK not in str(h.get("command", ""))]
        if inner:
            matcher["hooks"] = inner
            kept.append(matcher)
    if kept: hooks[event] = kept
    else: hooks.pop(event, None)

if mode != "--uninstall":
    # Notification  -> Claude is asking for permission or input
    # Stop          -> Claude finished its turn; it is now your move
    # UserPromptSubmit -> you replied, so it is working again
    # SessionStart / SessionEnd -> appear and disappear promptly
    for event in ["Notification", "Stop", "UserPromptSubmit", "SessionStart", "SessionEnd"]:
        hooks.setdefault(event, []).append(collections.OrderedDict([
            ("hooks", [collections.OrderedDict([
                ("type", "command"),
                ("command", f'"{hook}" {event}'),
            ])])
        ]))

if not hooks: cfg.pop("hooks", None)
with open(settings_path, "w") as f:
    json.dump(cfg, f, indent=2); f.write("\n")
print(("removed" if mode == "--uninstall" else "installed") + f" OnePlaceTerminal hooks in {settings_path}")
PY
echo "Restart your Claude sessions (or start new ones) for the hooks to take effect."
