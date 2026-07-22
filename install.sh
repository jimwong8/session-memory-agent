#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${HOME}/.session-memory-agent"
API="${SESSION_MEMORY_API:-http://100.77.184.40:8000}"

echo "[INFO] Installing session-memory-hook v3.0 to $INSTALL_DIR (API: $API)"
mkdir -p "$INSTALL_DIR"

# Download memory_hook.py from GitHub
curl -sL "https://raw.githubusercontent.com/jimwong8/session-memory-agent/main/memory_hook.py" -o "$INSTALL_DIR/memory_hook.py"
chmod +x "$INSTALL_DIR/memory_hook.py"

# Download hook.sh from GitHub  
curl -sL "https://raw.githubusercontent.com/jimwong8/session-memory-agent/main/hook.sh" -o "$INSTALL_DIR/hook.sh"

# Init
touch "$INSTALL_DIR/.init"

# Add to bashrc
if ! grep -q "hook.sh" ~/.bashrc 2>/dev/null; then
    echo '' >> ~/.bashrc
    echo '# Session Memory Hook v3.0' >> ~/.bashrc
    echo 'export SESSION_MEMORY_API="http://100.77.184.40:8000"' >> ~/.bashrc
    echo 'export SMH_DIR="$HOME/.session-memory-agent"' >> ~/.bashrc
    echo 'source "$SMH_DIR/hook.sh"' >> ~/.bashrc
    echo "[OK] Added to ~/.bashrc"
fi

# Start session
python3 "$INSTALL_DIR/memory_hook.py" start &
sleep 1
echo "[OK] Hook v3.0 installed"
echo "[INFO] Restart terminal or run: source ~/.bashrc"