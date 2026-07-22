#!/usr/bin/env bash
set -euo pipefail
INSTALL_DIR="${HOME}/.session-memory-agent"
API="${SESSION_MEMORY_API:-http://100.77.184.40:8000}"
echo "[INFO] Installing session-memory-hook v3.0 to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
curl -sL "https://raw.githubusercontent.com/jimwong8/session-memory-agent/main/memory_hook.py" -o "$INSTALL_DIR/memory_hook.py"
chmod +x "$INSTALL_DIR/memory_hook.py"
curl -sL "https://raw.githubusercontent.com/jimwong8/session-memory-agent/main/hook.sh" -o "$INSTALL_DIR/hook.sh"
touch "$INSTALL_DIR/.init"
if ! grep -q hook.sh ~/.bashrc 2>/dev/null; then
  echo >> ~/.bashrc
  echo '# Session Memory Hook v3.0' >> ~/.bashrc
  echo 'export SESSION_MEMORY_API="http://100.77.184.40:8000"' >> ~/.bashrc
  echo 'export SMH_DIR="$HOME/.session-memory-agent"' >> ~/.bashrc
  echo 'source "$SMH_DIR/hook.sh"' >> ~/.bashrc
  echo "[OK] Added to ~/.bashrc"
fi
echo "[OK] v3.0 installed. Run: source ~/.bashrc"