#!/usr/bin/env bash
set -euo pipefail
D="$HOME/.session-memory-agent"
A="${SESSION_MEMORY_API:-http://100.77.184.40:8000}"
echo "[v3.0] Installing to $D"
mkdir -p "$D"
for f in memory_hook.py hook.sh; do
  curl -sL "https://raw.githubusercontent.com/jimwong8/session-memory-agent/main/$f" -o "$D/$f"
done
chmod +x "$D/memory_hook.py"
touch "$D/.init"
grep -q hook.sh ~/.bashrc 2>/dev/null || { echo >>~/.bashrc; echo '# Memory Hook v3.0'>>~/.bashrc; echo 'export SMH_DIR="$HOME/.session-memory-agent"'>>~/.bashrc; echo "source \$SMH_DIR/hook.sh">>~/.bashrc; }
echo "[OK] Run: source ~/.bashrc"