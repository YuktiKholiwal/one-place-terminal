# One Place Terminal

A macOS menu bar app that shows every terminal session on your machine — which
one is waiting on you, which is working, and which you forgot about three days
ago.

    ┌─ Sessions ───────── 14 · 8 projects ┐
    │ WAITING ON YOU                    2 │
    │ ● hackernews    claude          16m │
    │ ● chess         claude          10m │
    │ RUNNING                           2 │
    │ ● chess      npm run dev  :3000  3d │
    │ ● makeup        claude          19m │
    │ STALE                             9 │
    │ ○ chess         claude          12d │
    └─ live · 0.8ms ─────────────── Quit ─┘

## Install

    ./build.sh && open OnePlaceTerminal.app

It lives in the menu bar — no Dock icon, no ⌘-Tab entry. The badge shows how
many sessions are waiting on you.

## How it works

A terminal session is a TTY. The scanner reads the kernel process table
directly — `sysctl(KERN_PROC_ALL)` for the process list, `KERN_PROCARGS2` for
real command lines, `proc_pidinfo` for working directories and listening
sockets. It spawns nothing.

That matters more than it sounds. The first version shelled out to `ps` and
`lsof` and cost **323ms per scan**, because Foundation's `Process` costs ~75ms
per spawn on this machine regardless of the command. Reading the kernel
directly costs **0.8ms** — the same data, 400× cheaper.

Two details worth knowing:

- **The foreground command is the shell's direct child**, not the deepest
  descendant. That is what makes a row read `npm run dev` rather than
  `next-server (v16.3.4)`.
- **`kp_proc.p_comm` is useless** — it is capped at 16 bytes, and for a Claude
  session it reads `2.1.261`, the version string. Hence `KERN_PROCARGS2`.

## Optional: the "waiting on you" signal

The process table cannot tell a Claude that is *thinking* from one that is
*waiting for your reply* — both are just a running `claude`. Claude Code hooks
supply that:

    ./hooks/install-hooks.sh          # adds hooks to ~/.claude/settings.json
    ./hooks/install-hooks.sh --uninstall

This is global: it affects every Claude Code session you run. It backs up your
settings first. Each hook writes one small file keyed by the `claude` process
id, which is how six sessions in the same folder stay distinguishable.

Without it the app still works — those sessions just read as "running".

## Optional: click a row to focus that terminal

    ./vscode-extension/install.sh     # then reload VS Code

`Terminal.processId` in the VS Code API returns the shell pid, which is exactly
the key the scanner reports, so the mapping is exact. Each VS Code window binds
its own socket and the app tries them in turn.

Without the extension, clicking a row opens its folder instead.

## Crash recovery

Your conversations are never at risk: Claude Code appends each one to
`~/.claude/projects/.../<session-id>.jsonl` as it goes, and that survives a
crash. What is easy to lose is the *arrangement* — which sessions were open, in
which folders, under which ids. The app records that.

    ./restore.sh              # what would come back
    ./restore.sh --run        # recreate them as VS Code terminals
    ./restore.sh --print      # raw commands, to paste anywhere
    ./restore.sh --history    # earlier snapshots

A snapshot is written atomically to
`~/Library/Application Support/OnePlaceTerminal/snapshot.json` every time the
session set changes, and the last 24 are kept in `history/` — a crash often
happens just *after* you closed something, so the newest state is not always the
one you want. The whole thing costs about 8 KB.

Restoring a Claude session uses `claude --resume <id>`, so the conversation
continues rather than starting over.

### Agents

The app recognises the agent running in each terminal and records how to bring
that specific conversation back:

| Agent | Session store | Resume |
|---|---|---|
| Claude Code | `~/.claude/projects/<cwd>/<uuid>.jsonl` | `claude --resume <uuid>` |
| fx | `~/.fx/sessions/index.json` | `fx session resume <id>` |
| Codex | `~/.codex/sessions/<date>/rollout-*.jsonl` | `codex resume <uuid>` |
| Gemini | per-project, index addressed | `gemini --resume latest` |

Each agent files its sessions differently. fx keeps an index carrying
`workspace_root` and `created_at_ms`, so no guessing is needed. Claude Code uses
one directory per project. Codex files rollouts **by date, not by project**, so
the working directory has to be read out of each file's first record — and that
record can exceed 16 KB, because newer versions inline the full base
instructions. Gemini resumes by position rather than id, which goes stale as
soon as new sessions appear, so `latest` is the only honest command to record.

Adding an agent means writing one `AgentAdapter` in `AgentRegistry.swift`:
where its sessions live, and how to resume one.

### Finding the session id without hooks

No agent exposes its session id through the process, so it cannot be read off
the process table. But they all record a conversation when one starts, so the
conversation's **creation time** lines up with the process's start time. Measured across
live sessions, the gap ran from 3 to 100 seconds — enough to match every session
uniquely, including several running in the same folder:

    pid 16033  started 14:01:04   ->  c91cc28a  born 14:01   (Δ3s)
    pid 14561  started 12:02:54   ->  e0f080a1  born 12:03   (Δ14s)

Oldest process claims the oldest unclaimed transcript, so the matching cannot
collide. A resumed session appends to an existing transcript, whose birth time
belongs to the original session, so those fall back to most-recently-modified.
When hooks are installed they report the id exactly and always win.

## Actions

- **Click a row** — focus that terminal (or open its folder)
- **Hover → ×, then confirm** — `SIGTERM` the session, which closes the tab

## Cost

| | |
|---|---|
| Bundle | 528 KB |
| Memory | 14 MB private |
| Scan | ~1.5 ms |
| CPU, popover closed | 0.12% of one core |
| Subprocesses | none |

Two things keep the idle cost down, and both were worth more than making the
scan itself faster:

- **Sessions store absolute start times, not elapsed ages.** An elapsed value
  changes every second, so no two scans ever compare equal and the menu bar
  item re-renders forever. Storing start dates and deriving age at display time
  means an unchanged machine produces an unchanged list, and nothing redraws.
- **Polling slows to 5s when the popover is closed.** Nothing is visible but the
  badge. Together these took idle CPU from 1.4% to 0.12%.
