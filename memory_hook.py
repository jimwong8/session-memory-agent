#!/usr/bin/env python3
import os, sys, json, time
from pathlib import Path
import urllib.request, urllib.error

SMH_DIR = Path(os.environ.get("SMH_DIR", Path.home() / ".session-memory-agent"))
API = os.environ.get("SESSION_MEMORY_API", "http://100.77.184.40:8000")
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

def start(resume_words=None):
    payload = {"title": f"{HOST}:{USER_ID}@{time.strftime('%Y%m%d-%H%M')}", "user_id": USER_ID,
        "metadata_json": {"host": HOST, "source": "session-memory-agent", "os": os.uname().sysname}}
    r = api_post("/api/v1/sessions", payload)
    if "id" in r:
        sid_file = Path(__file__).parent / ".session_id"
        sid_file.write_text(r["id"])
        return r["id"]
    return None

def tick(user_msg, reply_msg, tags=None):
    sid_file = Path(__file__).parent / ".session_id"
    if not sid_file.exists():
        start()
    sid = sid_file.read_text().strip()
    payload = {"session_id": sid, "event_seq": int(time.time()), "event_type": "conversation",
        "content": {"user": user_msg[:500], "assistant": reply_msg[:1000]},
        "terminal_id": HOST, "project_key": "session-memory-agent", "metadata": tags or []}
    r = api_post("/api/v1/events", payload)
    try:
        batch = []
        if user_msg: batch.append({"session_id": sid, "role": "user", "content": user_msg, "ts": time.time()})
        if reply_msg: batch.append({"session_id": sid, "role": "assistant", "content": reply_msg, "ts": time.time()})
        if batch: api_post("/api/v1/messages/batch", batch)
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

def watch_hermes():
    hdb = Path.home() / ".hermes/state.db"
    sync_file = SMH_DIR / ".last_synced_id"
    if not hdb.exists(): return
    import sqlite3
    conn = sqlite3.connect(str(hdb))
    last_id = 0
    if sync_file.exists():
        try: last_id = int(sync_file.read_text().strip())
        except: pass
    rows = conn.execute("""SELECT id, session_id, role, content, timestamp FROM messages
        WHERE id > ? AND role IN ('user','assistant')
        AND content IS NOT NULL AND length(content) > 10 AND active = 1
        ORDER BY id LIMIT 50""", (last_id,)).fetchall()
    if not rows:
        conn.close(); return
    batch = []
    for row in rows:
        batch.append({"session_id": row[1], "role": row[2], "content": row[3][:8000], "ts": row[4]})
    tid_file = SMH_DIR / ".terminal_id"
    if tid_file.exists():
        for row in rows:
            api_post(f"/api/v1/terminals/{tid_file.read_text().strip()}/share", {"session_id": row[1], "can_share": False})
    resp = api_post("/api/v1/messages/batch", batch)
    sync_file.write_text(str(rows[-1][0]))
    if isinstance(resp, dict) and "error" not in resp:
        print(f"[smh-watch] synced {len(rows)} Hermes msgs (id {last_id} -> {rows[-1][0]})")
    conn.close()

if __name__ == "__main__":
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument("command", choices=["start","tick","close","status","watch"])
    p.add_argument("--resume", help="keyword")
    p.add_argument("--user", help="user input")
    p.add_argument("--reply", help="assistant reply")
    p.add_argument("--tags", help="tags")
    p.add_argument("--summary", help="summary")
    args = p.parse_args()
    if args.command == "start": start(args.resume)
    elif args.command == "tick": tick(args.user or "", args.reply or "", args.tags.split(",") if args.tags else None)
    elif args.command == "close": close(args.summary or "")
    elif args.command == "watch": watch_hermes()
    elif args.command == "status": status()