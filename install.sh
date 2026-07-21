#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

INSTALL_DIR="${HOME}/.session-memory-agent"
API_HOST="${1:-10.100.1.13}"
API="http://${API_HOST}:8000"

info "Installing session-memory-hook to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

# Python daemon + queue
cat > "$INSTALL_DIR/memory_hook.py" << 'PYEOF'
#!/usr/bin/env python3
"""session-memory-hook v2 — Local queue + background daemon + auto-migration."""
import os, sys, json, time, sqlite3, signal
from pathlib import Path
import urllib.request, urllib.error

SMH_DIR = Path(os.environ.get("SMH_DIR", Path.home() / ".session-memory-agent"))
API = os.environ.get("SMH_API", "http://10.100.1.13:8000")
QUEUE_DB = SMH_DIR / "queue.db"
SESSION_FILE = SMH_DIR / ".session_id"

def db():
    c = sqlite3.connect(str(QUEUE_DB))
    c.execute("CREATE TABLE IF NOT EXISTS queue (id INTEGER PRIMARY KEY AUTOINCREMENT, role TEXT, content TEXT, ts REAL, synced INT DEFAULT 0)")
    c.commit()
    return c

def enqueue(role, content, ts=None):
    if ts is None: ts = time.time()
    c = db()
    c.execute("INSERT INTO queue (role, content, ts) VALUES (?,?,?)", (role, content[:8000], ts))
    c.commit(); c.close()

def drain(limit=50):
    c = db()
    rows = c.execute("SELECT id, role, content, ts FROM queue WHERE synced=0 ORDER BY id LIMIT ?", (limit,)).fetchall()
    c.close()
    return rows

def mark_synced(ids):
    if not ids: return
    c = db()
    c.executemany("UPDATE queue SET synced=1 WHERE id=?", [(i,) for i in ids])
    c.commit(); c.close()

def qsize():
    c = db()
    r = c.execute("SELECT count(*) FROM queue WHERE synced=0").fetchone()[0]
    c.close()
    return r

def api_post(path, data, timeout=30):
    req = urllib.request.Request(f"{API}{path}", data=json.dumps(data).encode(),
        headers={"Content-Type": "application/json"})
    try:
        r = urllib.request.urlopen(req, timeout=timeout)
        return json.loads(r.read())
    except urllib.error.HTTPError as e:
        return {"error": f"HTTP {e.code}"}
    except Exception as e:
        return {"error": str(e)}

def get_or_create_session():
    if SESSION_FILE.exists():
        return SESSION_FILE.read_text().strip()
    hostname = os.uname().nodename
    user = os.environ.get("USER", "unknown")
    r = api_post("/api/v1/sessions", {
        "title": f"{hostname}:{user}@{time.strftime('%Y%m%d-%H%M')}",
        "user_id": user,
        "metadata_json": {"source": "smh", "hostname": hostname}
    })
    if "id" in r:
        SESSION_FILE.write_text(r["id"])
        return r["id"]
    return None

def run_hook():
    """Called on each prompt"""
    try:
        import subprocess
        result = subprocess.run(["bash", "-c", "history 1 | sed 's/^ *[0-9]* *//'"], capture_output=True, text=True)
        cmd = result.stdout.strip()
        if not cmd or len(cmd) < 5: return
        trivial = {'ls', 'cd', 'pwd', 'clear', 'exit', 'cat', 'echo', 'man', 'history', 'll', 'la'}
        if cmd.split()[0] in trivial: return
        sid = get_or_create_session()
        if sid:
            enqueue("user", "$ " + cmd)
    except: pass

def run_daemon():
    """Continuous sync"""
    sid = get_or_create_session()
    if not sid: sys.exit(1)
    while True:
        items = drain(20)
        if not items:
            time.sleep(2); continue
        ids = []
        for mid, role, content, ts in items:
            r = api_post(f"/api/v1/sessions/{sid}/messages", {"role": role, "content": content})
            ids.append(mid)
        mark_synced(ids)
        if ids:
            print(f"[smh] synced {len(ids)} (pending: {qsize()})")
        time.sleep(0.5)

def migrate_bash():
    bash = Path.home() / ".bash_history"
    if not bash.exists(): return
    lines = bash.read_text().splitlines()
    for line in lines:
        line = line.strip()
        if line and len(line) > 3:
            enqueue("user", "$ " + line)
    print(f"[smh] queued {len(lines)} bash cmds")

def migrate_hermes():
    hdb = Path.home() / ".hermes/state.db"
    if not hdb.exists(): return
    import sqlite3
    conn = sqlite3.connect(str(hdb))
    for s in conn.execute("SELECT id FROM sessions WHERE source IN ('cli','tui') AND message_count > 0 ORDER BY started_at"):
        for m in conn.execute("SELECT role, content, ts FROM messages WHERE session_id=? AND role IN ('user','assistant') AND length(content) > 20 ORDER BY timestamp", (s[0],)):
            if "[IMPORTANT" in m[1][:80]: continue
            enqueue(m[0], m[1], m[2])
    conn.close()

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "hook": run_hook()
    elif cmd == "daemon": run_daemon()
    elif cmd == "migrate":
        migrate_bash()
        migrate_hermes()
    elif cmd == "status":
        print(f"[smh] pending: {qsize()}")
    else:
        print("Usage: memory_hook.py {hook|daemon|migrate|status}")
PYEOF
chmod +x "$INSTALL_DIR/memory_hook.py"

# Shell hook
cat > "$INSTALL_DIR/hook.sh" << 'SHEOF'
export SMH_DIR="${SMH_DIR:-$HOME/.session-memory-agent}"
_smh() {
    [ -f "$SMH_DIR/.init" ] || return
    local cmd="$(history 1 | sed 's/^ *[0-9]* *//')"
    [ -n "$cmd" ] || return
    case "$cmd" in ls*|cd*|pwd*|clear*|exit*) return ;; esac
    [ ${#cmd} -gt 4 ] || return
    ( python3 "$SMH_DIR/memory_hook.py" hook & ) >/dev/null 2>&1
}
_SMH_DAEMON="python3 $SMH_DIR/memory_hook.py daemon"
if ! pgrep -f "$_SMH_DAEMON" >/dev/null 2>&1; then
    nohup $_SMH_DAEMON >/dev/null 2>&1 &
fi
PROMPT_COMMAND="_smh${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
SHEOF

# Init
touch "$INSTALL_DIR/.init"
daemon_pid=$!
ok "Hook installed ($INSTALL_DIR)"
(kill -0 $daemon_pid 2>/dev/null) && ok "Daemon running: $daemon_pid" || warn "Daemon will start after shell restart"

# Add to bashrc
if ! grep -q "hook.sh" ~/.bashrc 2>/dev/null; then
    echo '' >> ~/.bashrc
    echo '# Session Memory Hook' >> ~/.bashrc
    echo 'export SMH_DIR="$HOME/.session-memory-agent"' >> ~/.bashrc
    echo 'source "$SMH_DIR/hook.sh"' >> ~/.bashrc
    ok "Added to ~/.bashrc"
fi

# Migrate on first run
info "Starting historical migration in background..."
nohup python3 "$INSTALL_DIR/memory_hook.py" migrate >/dev/null 2>&1 &
ok "Migration started"
info "Restart terminal to activate hook, or run: source ~/.bashrc"
