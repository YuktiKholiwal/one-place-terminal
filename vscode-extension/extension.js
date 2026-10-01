const vscode = require('vscode');
const net = require('net');
const fs = require('fs');
const os = require('os');
const path = require('path');

// Each VS Code window runs its own extension host, so each binds its own socket
// and the app tries them in turn. One shared path would let only one window win.
const SUPPORT = path.join(os.homedir(), 'Library/Application Support/OnePlaceTerminal');
const DIR = path.join(SUPPORT, 'focus');
const SNAPSHOT = path.join(SUPPORT, 'snapshot.json');
const SOCK = path.join(DIR, `w${process.pid}.sock`);

/** Terminal.processId is the shell pid — the same key the scanner reports. */
async function focusByShellPID(pid) {
  for (const term of vscode.window.terminals) {
    let termPID;
    try { termPID = await term.processId; } catch { continue; }
    if (termPID === pid) {
      term.show(false);           // reveal the terminal, keep focus in it
      return true;
    }
  }
  return false;
}

/**
 * Recreates the terminals recorded in the last snapshot. Claude sessions come
 * back with `claude --resume <id>`, so the conversation continues rather than
 * starting over.
 */
async function restoreSessions(entries) {
  // Called either with an explicit list from the app (which knows what is
  // already running) or with nothing, in which case fall back to the snapshot.
  if (!entries) {
    const snap = JSON.parse(fs.readFileSync(SNAPSHOT, 'utf8'));
    entries = (snap.sessions || []).map((s) => ({
      cwd: s.cwd, name: s.project, restore: s.restore,
    }));
  }
  let made = 0;
  for (const e of entries) {
    if (!e.cwd) continue;
    const term = vscode.window.createTerminal({ name: e.name || 'session', cwd: e.cwd });
    if (e.restore) term.sendText(e.restore);
    made++;
  }
  return made;
}

function activate(context) {
  fs.mkdirSync(DIR, { recursive: true });
  try { fs.unlinkSync(SOCK); } catch {}   // clear a socket left by a crash

  const server = net.createServer((conn) => {
    conn.on('data', async (buf) => {
      const msg = String(buf).trim();
      if (msg === 'restore' || msg.startsWith('restore ')) {
        try {
          const rest = msg.slice('restore'.length).trim();
          const n = await restoreSessions(rest ? JSON.parse(rest) : null);
          conn.end(`restored ${n}\n`);
        } catch (e) {
          conn.end(`error ${e.message}\n`);
        }
        return;
      }
      const pid = parseInt(msg, 10);
      if (!Number.isFinite(pid)) { conn.end('bad\n'); return; }
      let ok = false;
      try { ok = await focusByShellPID(pid); } catch {}
      conn.end(ok ? 'ok\n' : 'miss\n');
    });
    conn.on('error', () => {});
  });

  server.on('error', (e) => console.error('[oneplace] socket error', e.message));
  server.listen(SOCK, () => console.log('[oneplace] listening on', SOCK));

  context.subscriptions.push(
    vscode.commands.registerCommand('oneplace.restoreSessions', async () => {
      try {
        const n = await restoreSessions(null);
        vscode.window.showInformationMessage(`One Place: restored ${n} sessions.`);
      } catch (e) {
        vscode.window.showErrorMessage(`One Place: ${e.message}`);
      }
    })
  );

  context.subscriptions.push({
    dispose() {
      try { server.close(); } catch {}
      try { fs.unlinkSync(SOCK); } catch {}
    },
  });
}

function deactivate() {
  try { fs.unlinkSync(SOCK); } catch {}
}

module.exports = { activate, deactivate };
