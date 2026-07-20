#!/usr/bin/env bash
# session-memory-agent install.sh
# 一键部署：下载安装 + 配置自动化 + 对接会话记忆系统
# 支持: macOS / Linux (Debian/Ubuntu/CentOS) / Windows Git Bash
# 用法: curl -fsSL https://raw.githubusercontent.com/jimwong8/session-memory-agent/main/install.sh | bash

set -euo pipefail

# === 颜色 ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

# === 配置 ===
REPO_OWNER="${REPO_OWNER:-jimwong8}"
REPO_NAME="${REPO_NAME:-session-memory-agent}"
REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}.git"
INSTALL_DIR="${HOME}/.session-memory-agent"
SESSION_MEMORY_HOST="${SESSION_MEMORY_HOST:-10.100.1.13}"
SESSION_MEMORY_API="http://${SESSION_MEMORY_HOST}:8000"
CSS_API="http://${SESSION_MEMORY_HOST}:8443"
USER_ID="${USER:-$(whoami)}"
HOSTNAME="$(hostname)"

# === 检测系统 ===
detect_os() {
    case "$(uname -s)" in
        Linux*)  echo "linux" ;;
        Darwin*) echo "macos" ;;
        MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
        *) err "不支持的系统: $(uname -s)" ;;
    esac
}

OS=$(detect_os)
info "检测到系统: $OS"

# === 检查依赖 ===
check_deps() {
    local missing=()
    # Windows uses 'python' not 'python3'
    if [ "$OS" = "windows" ]; then
        if command -v python &>/dev/null; then
            :
        else
            missing+=("python")
        fi
    elif ! command -v python3 &>/dev/null; then
        missing+=("python3")
    fi
    for cmd in git curl; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    # pip check (module form)
    if [ "$OS" = "windows" ]; then
        if ! python -m pip --version &>/dev/null 2>&1; then
            missing+=("pip")
        fi
    elif ! command -v pip3 &>/dev/null 2>&1; then
        missing+=("pip3")
    fi
    if [ ${#missing[@]} -gt 0 ]; then
        warn "缺少依赖: ${missing[*]}"
        info "正在尝试自动安装..."
        if [ "$OS" = "linux" ]; then
            if command -v apt-get &>/dev/null; then
                sudo apt-get update -qq && sudo apt-get install -y -qq python3 python3-pip git curl
            elif command -v yum &>/dev/null; then
                sudo yum install -y python3 python3-pip git curl
            else
                err "不支持的包管理器，请手动安装: ${missing[*]}"
            fi
        elif [ "$OS" = "macos" ]; then
            if ! command -v brew &>/dev/null; then
                /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            fi
            brew install python3 git curl
        else
            err "Windows 请手动安装: ${missing[*]}"
        fi
    fi
    ok "依赖检查通过"
}

check_deps

# === 创建虚拟环境 ===
info "创建 Python 虚拟环境..."
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

if [ ! -d .venv ]; then
    python3 -m venv .venv 2>/dev/null || python -m venv .venv
fi
if [ "$OS" = "windows" ]; then
    source .venv/Scripts/activate
else
    source .venv/bin/activate
fi
ok "虚拟环境就绪"

# === 复制脚本 ===
info "安装脚本到 ${INSTALL_DIR}..."

# 配置
cat > config.json <<EOF
{
    "session_memory_api": "${SESSION_MEMORY_API}",
    "css_api": "${CSS_API}",
    "user_id": "${USER_ID}",
    "hostname": "${HOSTNAME}",
    "source": "session-memory-agent"
}
EOF

# memory_hook.py — 会话管理钩子
cat > memory_hook.py <<'PYEOF'
#!/usr/bin/env python3
"""session-memory-agent: 会话记忆钩子"""
import sys, os, json, uuid, time, urllib.request, urllib.error
from pathlib import Path

CONFIG = json.load(open(Path(__file__).parent / "config.json"))
API = CONFIG["session_memory_api"]
USER_ID = CONFIG["user_id"]
HOST = CONFIG["hostname"]

def api_get(path):
    try:
        r = urllib.request.urlopen(f"{API}{path}", timeout=10)
        return json.loads(r.read())
    except Exception as e:
        return {"error": str(e)}

def api_post(path, data):
    try:
        req = urllib.request.Request(
            f"{API}{path}",
            data=json.dumps(data).encode(),
            headers={"Content-Type": "application/json", "Accept": "application/json"}
        )
        r = urllib.request.urlopen(req, timeout=10)
        return json.loads(r.read())
    except urllib.error.HTTPError as e:
        body = e.read().decode() if e.fp else ""
        return {"error": f"HTTP {e.code}", "detail": body}
    except Exception as e:
        return {"error": str(e)}

def start(resume_words=None):
    """初始化会话"""
    payload = {
        "title": f"{HOST}:{USER_ID}@{time.strftime('%Y%m%d-%H%M')}",
        "user_id": USER_ID,
        "metadata_json": {"host": HOST, "source": "session-memory-agent", "os": os.uname().sysname}
    }
    r = api_post("/sessions", payload)
    if "id" in r:
        ok(f"会话已创建: {r['id'][:12]}")
        # 保存会话 ID
        sid_file = Path(__file__).parent / ".session_id"
        sid_file.write_text(r["id"])
    else:
        warn(f"创建失败: {r}")
    return r

def tick(user_msg, reply_msg, tags=None):
    """保存对话到事件流"""
    sid_file = Path(__file__).parent / ".session_id"
    if not sid_file.exists():
        start()
    sid = sid_file.read_text().strip()
    
    # 写 CSS 事件流
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
    return r

def close(summary=""):
    """结束会话"""
    return {"status": "closed", "summary": summary, "time": time.strftime("%Y-%m-%dT%H:%M:%SZ")}

def status():
    """查看连接状态"""
    h = api_get("/health")
    s = api_get(f"/sessions/recent?limit=1")
    return {"health": h, "latest_session": s}

def ok(m): print(f"  [OK] {m}")
def warn(m): print(f"  [WARN] {m}")

if __name__ == "__main__":
    import argparse
    p = argparse.ArgumentParser(description="Session Memory Agent Hook")
    p.add_argument("command", choices=["start","tick","close","status"])
    p.add_argument("--resume", help="恢复关键词")
    p.add_argument("--user", help="用户输入")
    p.add_argument("--reply", help="助手回复")
    p.add_argument("--tags", help="标签")
    p.add_argument("--summary", help="会话摘要")
    args = p.parse_args()
    
    if args.command == "start":
        start(args.resume)
    elif args.command == "tick":
        if not args.user or not args.reply:
            print("  --user 和 --reply 必填")
            sys.exit(1)
        tick(args.user, args.reply, args.tags.split(",") if args.tags else None)
    elif args.command == "close":
        print(close(args.summary))
    elif args.command == "status":
        print(status())
PYEOF

# bash_memory_hook.sh — bash 自动对接
cat > bash_memory_hook.sh <<'SHEOF'
# session-memory-agent bash 钩子
# 用法: source ~/.session-memory-agent/bash_memory_hook.sh
export SMA_DIR="${HOME}/.session-memory-agent"
export SMA_SESSION_FILE="${SMA_DIR}/.session_id"

_sma_tick() {
    local cmd="$(history 1 | sed 's/^[ ]*[0-9]*[ ]*//')"
    [ -z "$cmd" ] && return
    case "$cmd" in ls*|cd*|pwd*|clear*|exit*|cat*) return;; esac
    echo "$(date -Iseconds)	$(hostname)	${cmd}" >> "${SMA_DIR}/history_sync.log"
}

if [ -z "$SMA_INIT" ]; then
    export SMA_INIT=1
    python3 "${SMA_DIR}/memory_hook.py" start --resume "bash-$(date +%Y%m%d)" >/dev/null 2>&1 &
fi

PROMPT_COMMAND="_ma_tick;${PROMPT_COMMAND:-}"
SHEOF

# shell_history_sync.py — 跨终端历史同步
cat > shell_history_sync.py <<'PYEOF'
#!/usr/bin/env python3
"""跨终端历史同步: 本机历史 → 远程 Session Memory"""
import sys, os, json, time, urllib.request, urllib.error
from pathlib import Path

INSTALL_DIR = Path(__file__).parent
CONFIG = json.load(open(INSTALL_DIR / "config.json"))
API = CONFIG["session_memory_api"]
HISTORY_FILE = INSTALL_DIR / "history_sync.log"

def push_local():
    if not HISTORY_FILE.exists():
        print("无本地历史")
        return
    lines = HISTORY_FILE.read_text().strip().split("\n")
    pushed = 0
    for line in lines:
        parts = line.split("\t", 2)
        if len(parts) < 3: continue
        ts, host, cmd = parts
        payload = {
            "event_type": "shell_command",
            "terminal_id": host,
            "event_seq": int(time.time()),
            "content": {"command": cmd[:500], "timestamp": ts},
            "project_key": "session-memory-agent"
        }
        try:
            req = urllib.request.Request(
                f"{API}/api/v1/events",
                data=json.dumps(payload).encode(),
                headers={"Content-Type": "application/json"}
            )
            urllib.request.urlopen(req, timeout=10)
            pushed += 1
        except Exception as e:
            print(f"推送失败: {e}")
            break
    # 清空已推送
    HISTORY_FILE.write_text("")
    print(f"推送 {pushed} 条命令")

if __name__ == "__main__":
    push_local()
PYEOF

chmod +x memory_hook.py shell_history_sync.py bash_memory_hook.sh

ok "脚本安装完成"
echo ""
echo "=== 使用指南 ==="
echo ""
echo "1. 初始化会话 (每次终端启动):"
echo "   python3 ${INSTALL_DIR}/memory_hook.py start"
echo ""
echo "2. 对话 tick (每轮关键对话后):"
echo "   python3 ${INSTALL_DIR}/memory_hook.py tick --user \"问题\" --reply \"回答\""
echo ""
echo "3. Bash 自动对接 (加到 ~/.bashrc):"
echo "   echo 'source ${INSTALL_DIR}/bash_memory_hook.sh' >> ~/.bashrc"
echo "   source ~/.bashrc"
echo ""
echo "4. 跨终端历史同步 (cron 每小时):"
echo "   python3 ${INSTALL_DIR}/shell_history_sync.py"
echo ""
echo "5. 查看状态:"
echo "   python3 ${INSTALL_DIR}/memory_hook.py status"
echo ""
echo "===自动配置 ~/.bashrc 钩子 ==="
grep -q "bash_memory_hook.sh" ~/.bashrc 2>/dev/null && echo "已存在" || echo "source ${INSTALL_DIR}/bash_memory_hook.sh" >> ~/.bashrc
ok "~/.bashrc 已挂载"
echo ""
info "配置完成！请运行: source ~/.bashrc 或重启终端"
