#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

MARKER_DIR="/root/.demos_node_setup"
TMP_DIR="${MARKER_DIR}/tmp"
LOGFILE="$MARKER_DIR/install.log"
NODE_PATH="/root/node"
SYSTEMD_SERVICE="/etc/systemd/system/demos-node.service"
FIRST_REBOOT_MARKER="${MARKER_DIR}/.first_reboot_pending"
LOCKFILE="$MARKER_DIR/installer.lock"
BUN_PROFILE="/etc/profile.d/bun.sh"

mkdir -p "$TMP_DIR"
chmod 700 "$MARKER_DIR" "$TMP_DIR"

log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOGFILE"; }
write_marker(){ echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $1" > "$TMP_DIR/$1.tmp"; mv -f "$TMP_DIR/$1.tmp" "$MARKER_DIR/$1"; sync; }
marker_exists(){ [ -f "$MARKER_DIR/$1" ]; }

# Prevent parallel runs
exec 200>"$LOCKFILE"
flock -n 200 || { log "Another installer run active; exiting"; exit 1; }

log "Installer start"

# Wait for network helper
wait_for_network(){
  for i in {1..60}; do ip -4 addr show scope global | grep -q "inet " && return 0; sleep 1; done
  return 1
}

# Robust apt wrapper with lock handling and retries
apt_wait_and_run(){
  local cmd="$*"
  local attempts=0
  while true; do
    attempts=$((attempts+1))
    # stop apt timers that could hold locks
    sudo systemctl stop apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service >/dev/null 2>&1 || true
    # try to fix dpkg state first if flagged
    if [ -f /var/lib/dpkg/lock-frontend ] || [ -f /var/lib/dpkg/lock ]; then
      sleep 1
    fi
    sudo bash -c "$cmd" && return 0
    if [ $attempts -ge 10 ]; then
      log "apt command failed after $attempts attempts: $cmd"
      return 1
    fi
    sleep 3
  done
}

# Fix interrupted dpkg if necessary
if dpkg --audit >/dev/null 2>&1 || dpkg -l >/dev/null 2>&1 2>/dev/null; then
  if dpkg --audit | grep -qi 'interrupted\|half-installed\|not fully installed' 2>/dev/null || dpkg -C 2>/dev/null | grep -qi 'half-installed' 2>/dev/null; then
    log "Detected interrupted dpkg; running repair sequence"
    # ensure no apt/dpkg processes running and configure
    sudo killall -9 apt apt-get dpkg 2>/dev/null || true
    sudo dpkg --configure -a || true
    sudo apt-get -f install -y || true
    log "dpkg repair complete"
  fi
fi

# Protect /root/.bashrc from non-interactive PS1 errors
if ! grep -q "SKIP_INTERACTIVE_CONFIG_IF_NONINTERACTIVE" /root/.bashrc 2>/dev/null; then
  cp -a /root/.bashrc /root/.bashrc.bak 2>/dev/null || true
  cat > /root/.bashrc.new <<'EOF'
# SKIP_INTERACTIVE_CONFIG_IF_NONINTERACTIVE
# If shell is non-interactive, do not run interactive-only config below
case "$-" in
  *i*) ;;
  *) return;;
esac

# existing interactive config preserved below
EOF
  # append original .bashrc content after guard if exists
  if [ -f /root/.bashrc.bak ]; then
    tail -n +1 /root/.bashrc.bak >> /root/.bashrc.new || true
  fi
  mv -f /root/.bashrc.new /root/.bashrc
  log "Patched /root/.bashrc to guard interactive-only settings"
fi

# 1) Ensure unzip and curl early
if ! marker_exists unzip_installed; then
  log "Installing unzip and curl"
  apt_wait_and_run "apt-get update -y"
  apt_wait_and_run "apt-get install -y unzip curl"
  write_marker unzip_installed
fi

# 2) Update and base packages
if ! marker_exists system_updated; then
  log "Updating system and installing base packages"
  apt_wait_and_run "apt-get update -y"
  apt_wait_and_run "apt-get upgrade -y"
  apt_wait_and_run "apt-get install -y ca-certificates gnupg lsb-release wget git build-essential jq lsof software-properties-common gpg"
  write_marker system_updated
fi

# 3) One-time reboot scheduling
if ! marker_exists first_run_reboot_done && ! marker_exists first_run_reboot_scheduled; then
  log "Scheduling one-time reboot in 15s to finalize upgrades"
  write_marker first_run_reboot_scheduled
  touch "$FIRST_REBOOT_MARKER"
  echo -e "\n\033[1;41m  !!! ONE-TIME REBOOT IN 15s TO FINALIZE SETUP !!!  \033[0m"
  echo "After reboot wait ~60s then re-run: ~/demos_node_setup.sh"
  sleep 15
  reboot
  exit 0
fi

if marker_exists first_run_reboot_scheduled && ! marker_exists first_run_reboot_done; then
  write_marker first_run_reboot_done
  rm -f "$FIRST_REBOOT_MARKER" || true
  log "Post-reboot: continuing install"
fi

# 4) Install Docker
if ! marker_exists docker_installed; then
  log "Installing Docker"
  apt_wait_and_run "apt-get remove -y docker docker-engine docker.io containerd runc || true"
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list
  apt_wait_and_run "apt-get update -y"
  apt_wait_and_run "apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin"
  sudo systemctl enable --now docker || true
  write_marker docker_installed
  log "Docker installed"
fi

# 5) Install Bun and expose system-wide
if ! marker_exists bun_installed; then
  log "Installing Bun via official installer"
  curl -fsSL https://bun.sh/install | bash || true
  # Write system-wide profile if bun was installed under /root/.bun
  if [ -d "$HOME/.bun/bin" ]; then
    cat > "$BUN_PROFILE" <<'EOF'
# bun path for all users
export BUN_INSTALL="$HOME/.bun"
export PATH="$HOME/.bun/bin:$PATH"
EOF
    chmod 644 "$BUN_PROFILE"
    export BUN_INSTALL="$HOME/.bun"
    export PATH="$HOME/.bun/bin:$PATH"
    write_marker bun_installed
    log "Bun installed and profile written to $BUN_PROFILE"
  else
    log "Bun folder not found after install; continuing"
  fi
fi

# Ensure PATH in current shell
export PATH="$HOME/.bun/bin:$PATH" || true

# 6) Clone repo and install deps (bun preferred, pnpm fallback)
if ! marker_exists node_cloned; then
  log "Cloning node repository"
  rm -rf "$NODE_PATH"
  git clone -b testnet https://github.com/kynesyslabs/node.git "$NODE_PATH"
  pushd "$NODE_PATH" >/dev/null
  if command -v bun >/dev/null 2>&1; then
    log "Running bun install"
    if ! bun install; then
      log "bun install failed, will fallback"
    fi
  fi
  if [ ! -d node_modules ]; then
    log "Attempting pnpm fallback"
    apt_wait_and_run "curl -fsSL https://deb.nodesource.com/setup_20.x | bash -"
    apt_wait_and_run "apt-get install -y nodejs"
    if command -v npm >/dev/null 2>&1; then npm install -g pnpm || true; fi
    if command -v pnpm >/dev/null 2>&1; then
      pnpm install --ignore-scripts --shamefully-hoist || pnpm install --shamefully-hoist || true
    else
      npm ci || true
    fi
  fi
  bun pm trust --all >/dev/null 2>&1 || true
  popd >/dev/null
  write_marker node_cloned
  log "Node cloned and dependencies attempted"
fi

# 7) Create run-wrapper for systemd so Bun is visible
mkdir -p /root/node || true
cat > /root/node/run-wrapper.sh <<'EOF'
#!/bin/bash
export BUN_INSTALL=/root/.bun
export PATH=/root/.bun/bin:/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
cd /root/node
exec /bin/bash ./run
EOF
chmod +x /root/node/run-wrapper.sh
log "Created run-wrapper"

# 8) Write systemd service and enable it
cat > "$SYSTEMD_SERVICE" <<'EOF'
[Unit]
Description=Demos Node
After=network.target docker.service
Wants=docker.service

[Service]
Type=simple
User=root
WorkingDirectory=/root/node
ExecStart=/root/node/run-wrapper.sh
Restart=always
RestartSec=5
KillMode=process
LimitNOFILE=65536
Environment=PATH=/root/.bun/bin:/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=BUN_INSTALL=/root/.bun

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now demos-node.service || true
log "Systemd service installed and started"

# 9) Wait for keys generation up to 60s
if ! marker_exists keys_generated; then
  log "Waiting for keys up to 60s"
  tries=0
  while [ $tries -lt 60 ]; do
    if [ -f /root/node/publickey ] && [ -f /root/node/privatekey ]; then
      chmod 600 /root/node/privatekey || true
      write_marker keys_generated
      log "Keys generated"
      break
    fi
    tries=$((tries+1)); sleep 1
  done
  if ! marker_exists keys_generated; then
    log "Keys not generated yet; service may create them later"
  fi
fi

# 10) Configure .env and peerlist
if ! marker_exists node_configured; then
  PUBLIC_IP="$(curl -s --max-time 5 https://api.ipify.org || echo 127.0.0.1)"
  log "Configuring .env using public IP $PUBLIC_IP"
  mkdir -p /root/node || true
  if [ -f /root/node/env.example ]; then cp /root/node/env.example /root/node/.env; fi
  sed -i '/^EXPOSED_URL=/d' /root/node/.env 2>/dev/null || true
  echo "EXPOSED_URL=http://$PUBLIC_IP:53550" >> /root/node/.env
  if [ -f /root/node/publickey ]; then
    PUBKEY="$(cat /root/node/publickey)"
    echo "{\"$PUBKEY\":\"http://$PUBLIC_IP:53550\"}" > /root/node/demos_peerlist.json
  fi
  write_marker node_configured
  log ".env and peerlist written"
fi

# 11) Free port 5332 if used
if lsof -i :5332 &>/dev/null; then
  PIDS="$(lsof -t -i :5332 2>/dev/null || true)"
  if [ -n "$PIDS" ]; then
    log "Killing processes using port 5332: $PIDS"
    echo "$PIDS" | xargs -r -n1 kill || true
    sleep 2
  fi
fi

# 12) Final restart and status
systemctl restart demos-node.service || true
sleep 2
if systemctl is-active --quiet demos-node.service; then
  log "demos-node.service is active"
else
  log "demos-node.service not active; inspect journalctl -u demos-node.service -n 200"
fi

# 13) Convenience scripts
cat > /root/restart_demos_node.sh <<'EOF'
#!/bin/bash
systemctl restart demos-node.service
systemctl status demos-node.service --no-pager -l
EOF
chmod +x /root/restart_demos_node.sh

cat > /root/backup_demos_keys.sh <<'EOF'
#!/bin/bash
mkdir -p ~/demos-keys
cp /root/node/publickey ~/demos-keys/publickey 2>/dev/null || true
cp /root/node/privatekey ~/demos-keys/privatekey 2>/dev/null || true
chmod 600 ~/demos-keys/privatekey || true
ls -l ~/demos-keys || true
EOF
chmod +x /root/backup_demos_keys.sh

write_marker install_complete
log "Install complete. Check logs: journalctl -u demos-node.service -f"
