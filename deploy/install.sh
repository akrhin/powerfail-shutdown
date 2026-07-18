#!/bin/bash
# Install powerfail-agent on Proxmox
# Usage: bash <(curl -sL https://github.com/akrhin/powerfail-shutdown/releases/latest/download/install.sh)

set -euo pipefail

REPO="akrhin/powerfail-shutdown"
BIN_DIR="/usr/local/bin"
CONFIG_DIR="/etc/powerfail"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e " ${GREEN}✅${NC} $1"; }
warn() { echo -e " ${YELLOW}⚠️  $1${NC}"; }
err()  { echo -e " ${RED}❌${NC} $1"; }

[[ "$(id -u)" -ne 0 ]] && { err "Run as root."; exit 1; }
command -v qm &>/dev/null || { err "Not Proxmox (qm not found)"; exit 1; }

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  GOARCH="amd64" ;;
  aarch64) GOARCH="arm64" ;;
  *) err "Unsupported arch: $ARCH"; exit 1 ;;
esac

# Get latest release
echo "Detecting latest release..."
LATEST=$(curl -sL --connect-timeout 10 "https://api.github.com/repos/$REPO/releases/latest" | grep '"tag_name"' | head -1 | cut -d'"' -f4)
if [[ -z "$LATEST" ]]; then
  warn "Could not detect latest release, using main branch binary"
  LATEST="main"
fi

echo "Downloading powerfail-agent $LATEST ($GOARCH)..."
if [[ "$LATEST" == "main" ]]; then
  echo "⚠️  Fallback to main branch — no binaries in git, install may fail"
  warn "Binaries are not committed to git. Install from a tagged release instead."
  URL="https://github.com/$REPO/releases/latest/download/powerfail-agent-linux-$GOARCH"
else
  URL="https://github.com/$REPO/releases/download/$LATEST/powerfail-agent-linux-$GOARCH"
fi
curl -sL --connect-timeout 15 --max-time 60 -o "$BIN_DIR/powerfail-agent" "$URL"
chmod +x "$BIN_DIR/powerfail-agent"
ok "$BIN_DIR/powerfail-agent ($LATEST)"

# Create config directory
mkdir -p "$CONFIG_DIR"
if [[ ! -f "$CONFIG_DIR/powerfail.conf" ]]; then
  if [[ "$LATEST" == "main" ]]; then
    CONFIG_URL="https://raw.githubusercontent.com/$REPO/main/powerfail.toml.example"
  else
    CONFIG_URL="https://github.com/$REPO/releases/download/$LATEST/powerfail.toml.example"
  fi
  curl -sL --connect-timeout 10 "$CONFIG_URL" -o "$CONFIG_DIR/powerfail.conf" 2>/dev/null || true
  chmod 600 "$CONFIG_DIR/powerfail.conf" 2>/dev/null
  ok "$CONFIG_DIR/powerfail.conf created — edit and fill in your settings"
fi

# Install systemd units
echo ""
echo "Installing systemd units..."

cat > /etc/systemd/system/powerfail-agent.service << 'EOF'
[Unit]
Description=Powerfail Agent

[Service]
Type=oneshot
ExecStart=/usr/local/bin/powerfail-agent run --config /etc/powerfail/powerfail.conf
EOF

cat > /etc/systemd/system/powerfail-agent.timer << 'EOF'
[Unit]
Description=Powerfail Agent (check every 30s)
Requires=powerfail-agent.service

[Timer]
OnCalendar=*-*-* *:*:0/30
Persistent=false
AccuracySec=1

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable powerfail-agent.timer 2>/dev/null
systemctl start powerfail-agent.timer 2>/dev/null
ok "systemd timer installed and running"

echo ""
echo "============================================"
echo " Installation complete!"
echo "============================================"
echo ""
echo " Edit config:  nano $CONFIG_DIR/powerfail.conf"
echo ""
echo " Test:"
echo "   powerfail-agent test-network"
echo "   powerfail-agent test-telegram"
echo "   powerfail-agent dry-run"
echo ""
echo " Logs:"
echo "   journalctl -u powerfail-agent.service -f"
echo ""
echo " Timer status:"
echo "   systemctl status powerfail-agent.timer"
echo ""
echo " Config docs:"
echo "   https://github.com/$REPO"
echo ""
