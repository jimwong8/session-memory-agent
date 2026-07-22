#!/usr/bin/env bash
# session-memory-hook v3.0 — Terminal register + heartbeat + IP + watch + batch
export SMH_DIR="${SMH_DIR:-$HOME/.session-memory-agent}"
SMH_API="${SESSION_MEMORY_API:-http://100.77.184.40:8000}"

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

if [ -z "$_SMHM_HB_TIMER" ]; then
    _SMHM_HB_TIMER=1
    ( while true; do sleep 60; _smhm_heartbeat; done ) &
fi

_SMH_WATCH="python3 $SMH_DIR/memory_hook.py watch"
if ! pgrep -f "$_SMH_WATCH" >/dev/null 2>&1; then
    ( while true; do sleep 10; $_SMH_WATCH; done ) >/dev/null 2>&1 &
fi

_smhm_register
PROMPT_COMMAND="_smhm${PROMPT_COMMAND:+;$PROMPT_COMMAND}"