#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

INSTALL_DIR="${HOME}/.session-memory-agent"
API_HOST="${1:-100.77.184.40}"
API="http://${API_HOST}:8000"

info "Installing session-memory-hook v3.0 to $INSTALL_DIR (API: $API)"
mkdir -p "$INSTALL_DIR"

# ═══════════════════════════════════════
# Python core: memory_hook.py
# ═══════════════════════════════════════
cat > "$INSTALL_DIR/memory_hook.py" << 'PYEOF'
#!/usr/bin/env python3
"""session-memory-agent v3 — tick + batch + watch_hermes"""
import os, sys, json, time
from pathlib import Path
import urllib.request, urllib.error

SMH_DIR = Path(os.environ.get("SMH_DIR", Path.home() / ".session-memory-agent"))
API = os.environ.get("SMH_API", "http://100.77.184.40:8000")
HOST = os.uname().nodename
USER_ID = os.environ.get("USER", "unknown")

def api_get(path):
    try:
        r = urllib.request.urlopen(f"{API}{path}", timeout=10)
        return json.loads(r.read())
    except: return {}

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

def ok(m): print(f"  [OK] {m}")
def warn(m): print(f"  [WARN] {m}")

# ── Session management ──
def start(resume_words=None):
    payload = {
        "title": f"{HOST}:{USER_ID}@{time.strftime('%Y%m%d-%H%M')}",
        "user_id": USER_ID,
        "metadata_json": {"host": HOST, "source": "session-memory-agent", "os": os.uname().sysname}
    }
    r = api_post("/api/v1/sessions", payload)
    if "id" in r:
        ok(f"会话已创建: {r['id'][:12]}")
        sid_file = Path(__file__).parent / ".session_id"
        sid_file.write_text(r["id"])
        return r["id"]
    else:
        warn(f"会话创建失败: {r}")
        return None

def tick(user_msg, reply_msg, tags=None):
    """保存对话 — POST 到 /events + /messages/batch"""
    sid_file = Path(__file__).parent / ".session_id"
    if not sid_file.exists():
        start()
    sid = sid_file.read_text().strip()
    
    # 写事件流
    payload = {
        "session_id": sid,
        "event_seq": int(time.time()),
        "event_type": "conversation",
        "content": {"user": user_msg[:500], "assistant": reply_msg[:1000]},
        "terminal_id": HOST,
        "project_key": "session-memory-agent",
        "metadata": tags or []
    }
    r = api_post("/api/v1/events", payload)
    
    # 写缓冲池（完整内容 + 全文搜索）
    try:
        batch = []
        if user_msg:
            batch.append({"session_id": sid, "role": "user", "content": user_msg, "ts": time.time()})
        if reply_msg:
            batch.append({"session_id": sid, "role": "assistant", "content": reply_msg, "ts": time.time()})
        if batch:
            api_post("/api/v1/messages/batch", batch)
    except: pass
    
    return r

def close(summary=""):
    sid_file = Path(__file__).parent / ".session_id"
    if not sid_file.exists(): return
    sid = sid_file.read_text().strip()
    api_post(f"/api/v1/sessions/{sid}/summarize", {"summary": summary} if summary else {})

def status():
    sid_file = Path(__file__).parent / ".session_id"
    sid = sid_file.read_text().strip() if sid_file.exists() else "N/A"
    h = api_get("/health")
    print(f"  Session Memory API: {API}")
    print(f"  Health: {h.get('status', 'unknown')}")
    print(f"  Session: {sid}")
    print(f"  watch_hermes: available (python3 memory_hook.py watch)")

# ── Hermes state.db incremental sync ──
def watch_hermes():
    """增量同步 Hermes state.db → /messages/batch"""
    hdb = Path.home() / ".hermes/state.db"
    sync_file = SMH_DIR / ".last_synced_id"
    if not hdb.exists():
        return
    import sqlite3
    conn = sqlite3.connect(str(hdb))
    last_id = 0
    if sync_file.exists():
        try: last_id = int(sync_file.read_text().strip())
        except: pass
    rows = conn.execute(
        """SELECT id, session_id, role, content, timestamp 
           FROM messages WHERE id > ? AND role IN ('user','assistant') 
           AND content IS NOT NULL AND length(content) > 10 AND active = 1
           ORDER BY id LIMIT 50""",
        (last_id,)
    ).fetchall()
    if not rows:
        conn.close(); return
    
    batch = []
    for row in rows:
        batch.append({"session_id": row[1], "role": row[2], "content": row[3][:8000], "ts": row[4]})
    
    # Auto-link terminal to session
    tid_file = SMH_DIR / ".terminal_id"
    if tid_file.exists():
        for row in rows:
            api_post(f"/api/v1/terminals/{tid_file.read_text().strip()}/share",
                     {"session_id": row[1], "can_share": False})
    
    resp = api_post("/api/v1/messages/batch", batch)
    sync_file.write_text(str(rows[-1][0]))
    if isinstance(resp, dict) and "error" not in resp:
        print(f"[smh-watch] synced {len(rows)} Hermes msgs (id {last_id} -> {rows[-1][0]})")
    conn.close()

# ── CLI ──
if __name__ == "__main__":
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument("command", choices=["start","tick","close","status","watch"])
    p.add_argument("--resume", help="恢复关键词")
    p.add_argument("--user", help="用户输入")
    p.add_argument("--reply", help="助手回复")
    p.add_argument("--tags", help="标签")
    p.add_argument("--summary", help="会话摘要")
    args = p.parse_args()
    
    if args.command == "start":
        start(args.resume)
    elif args.command == "tick":
        tick(args.user or "", args.reply or "", args.tags.split(",") if args.tags else None)
    elif args.command == "close":
        close(args.summary or "")
    elif args.command == "watch":
        watch_hermes()
    elif args.command == "status":
        status()
PYEOF
chmod +x "$INSTALL_DIR/memory_hook.py"

# ═══════════════════════════════════════
# Shell hook v3.0
# ═══════════════════════════════════════
cat > "$INSTALL_DIR/hook.sh" << 'SHEOF'
#!/usr/bin/env bash
# session-memory-hook v3.0 — Terminal register + heartbeat + IP + watch + batch
export SMH_DIR="${SMH_DIR:-$HOME/.session-memory-agent}"
SMH_API="${SMH_API:-http://100.77.184.40:8000}"

_SMHM_TERMINAL_NAME="${SMH_TERMINAL_NAME:-$(hostname)-$$}"
_SMHM_HOSTNAME="$(hostname)"
_SMHM_OS="$(uname -s -r 2>/dev/null || uname -s)"

_smhm_detect_ip() {
    local ts_ip=$(tailscale ip -4 2>/dev/null)
    [ -n "$ts_ip" ] && echo "$ts_ip" && return
    local lan_ip=$(ip -4 addr show scope global 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    [ -n "$lan_ip" ] && echo "$lan_ip" && return
    echo "${host_ip:-unknown}"
}
_SMHM_IP="$(_smhm_detect_ip)"

_smhm_register() {
    [ -f "$SMH_DIR/.terminal_id" ] && return
    local resp=$(curl -s -m 10 -X POST "$SMH_API/api/v1/terminals/register" \
        -H "Content-Type: application/json" \
        -d "{\"terminal_name\":\"$_SMHM_TERMINAL_NAME\",\"hostname\":\"$_SMHM_HOSTNAME\",\"os_info\":\"$_SMHM_OS\",\"metadata_json\":{\"ip\":\"$_SMHM_IP\"}}")
    local tid=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
    [ -n "$tid" ] && echo "$tid" > "$SMH_DIR/.terminal_id"
}

_smhm_heartbeat() {
    local tid=$(cat "$SMH_DIR/.terminal_id" 2>/dev/null)
    [ -z "$tid" ] && return
    ( curl -s -m 5 -X POST "$SMH_API/api/v1/terminals/$tid/heartbeat" > /dev/null 2>&1 & )
}

_smhm() {
    [ -f "$SMH_DIR/.init" ] || return
    local cmd="$(history 1 | sed 's/^ *[0-9]* *//')"
    [ -n "$cmd" ] || return
    case "$cmd" in ls*|cd*|pwd*|clear*|exit*) return ;; esac
    [ ${#cmd} -gt 4 ] || return
    ( python3 "$SMH_DIR/memory_hook.py" tick --user "$cmd" --reply "" & )
}

# Heartbeat timer
if [ -z "$_SMHM_HB_TIMER" ]; then
    _SMHM_HB_TIMER=1
    ( while true; do sleep 60; _smhm_heartbeat; done ) &
fi

# Hermes state.db watcher (10s poll)
_SMH_WATCH="python3 $SMH_DIR/memory_hook.py watch"
if ! pgrep -f "$_SMH_WATCH" >/dev/null 2>&1; then
    ( while true; do sleep 10; $_SMH_WATCH; done ) >/dev/null 2>&1 &
fi

_smhm_register
PROMPT_COMMAND="_smhm${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
SHEOF

# ═══════════════════════════════════════
# Init & bashrc
# ═══════════════════════════════════════
touch "$INSTALL_DIR/.init"
ok "Hook v3.0 installed ($INSTALL_DIR)"

if ! grep -q "hook.sh" ~/.bashrc 2>/dev/null; then
    echo '' >> ~/.bashrc
    echo '# Session Memory Hook v3.0' >> ~/.bashrc
    echo 'export SMH_DIR="$HOME/.session-memory-agent"' >> ~/.bashrc
    echo 'source "$SMH_DIR/hook.sh"' >> ~/.bashrc
    ok "Added to ~/.bashrc"
else
    ok "~/.bashrc already configured"
fi

# Start session
python3 "$INSTALL_DIR/memory_hook.py" start &
sleep 1
ok "Session started"

info "Restart terminal or run: source ~/.bashrc"
info "API: $API"
