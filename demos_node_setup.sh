!/bin/bash
set -euo pipefail
IFS=$'\n\t'

============================================================

Demos Node installer - complete single-file script

- idempotent markers for each step

- reboot-aware: schedules one reboot and resumes

- apt-lock tolerant: retries and stops apt timers

- installs Docker, Bun, unzip, curl

- clones node repo, installs deps (bun/npm)

- creates run-wrapper and systemd unit

- waits for key generation, writes .env and demos_peerlist.json

- frees conflicting port, restarts service

- creates helper scripts and installs them to /usr/local/bin

- all user-facing output printed in bright red for visibility

============================================================

-------------------------

Paths and marker files

-------------------------
MARKERDIR="/root/.demosnode_setup"
TMPDIR="${MARKERDIR}/tmp"
LOGFILE="$MARKER_DIR/install.log"
NODE_PATH="/root/node"
SYSTEMD_SERVICE="/etc/systemd/system/demos-node.service"
FIRSTREBOOTMARKER="${MARKERDIR}/.firstreboot_pending"
LOCKFILE="$MARKER_DIR/installer.lock"
BUN_PROFILE="/etc/profile.d/bun.sh"
GLOBAL_BIN="/usr/local/bin"

Ensure marker dir exists
mkdir -p "$TMP_DIR"
chmod 700 "$MARKERDIR" "$TMPDIR" 2>/dev/null || true

-------------------------

Helpers

-------------------------
log(){ echo "[$(date '+%F %T')] $*" | tee -a "$LOGFILE"; }
red_echo(){ echo -e "\033[1;31m$*\033[0m"; }
writemarker(){ echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $1" > "$TMPDIR/$1.tmp" && mv -f "$TMPDIR/$1.tmp" "$MARKERDIR/$1" && sync; }
markerexists(){ [ -f "$MARKERDIR/$1" ]; }

Prevent parallel runs
exec 200>"$LOCKFILE"
flock -n 200 || { red_echo "❌ Another installer run is active. Exiting."; exit 1; }

-------------------------

Preflight detection

-------------------------
red_echo "🔍 Preflight check: scanning system for existing components..."
if command -v unzip >/dev/null && command -v curl >/dev/null; then redecho "✅ unzip and curl installed"; else redecho "❌ unzip or curl missing"; fi
if command -v docker >/dev/null; then redecho "✅ Docker installed: $(docker --version 2>/dev/null || echo 'unknown')"; else redecho "❌ Docker not found"; fi
if command -v bun >/dev/null; then redecho "✅ Bun installed: $(bun --version 2>/dev/null || echo 'unknown')"; else redecho "❌ Bun not found"; fi
[ -d "$NODEPATH" ] && redecho "✅ Node repo exists at $NODEPATH" || redecho "❌ Node repo missing"
systemctl list-units --type=service | grep -q demos-node.service && redecho "✅ Systemd service registered" || redecho "❌ Systemd service missing"
[ -f "$NODEPATH/publickey" ] && [ -f "$NODEPATH/privatekey" ] && redecho "✅ Node keys found" || redecho "❌ Node keys missing"
red_echo "🧪 Preflight complete. Proceeding..."

-------------------------

One-time reboot logic

-------------------------
if ! markerexists firstrunrebootdone && ! markerexists firstrunrebootscheduled; then
  writemarker firstrunrebootscheduled
  touch "$FIRSTREBOOTMARKER"
  red_echo "🚨 One-time reboot in 15s to finalize system upgrades"
  red_echo "After reboot, re-run this script or run the same curl command you used."
  sleep 15
  reboot
  exit 0
fi

if markerexists firstrunrebootscheduled && ! markerexists firstrunrebootdone; then
  writemarker firstrunrebootdone
  rm -f "$FIRSTREBOOTMARKER" || true
  red_echo "✅ Post-reboot: continuing install"
fi

-------------------------

Apt wrapper with retries

-------------------------
aptwaitand_run(){
  local cmd="$*"
  for i in {1..12}; do
    sudo systemctl stop apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service >/dev/null 2>&1 || true
    sudo bash -c "$cmd" && return 0
    sleep 3
  done
  red_echo "❌ apt command failed after retries: $cmd"
  return 1
}

-------------------------

Install unzip and curl

-------------------------
if ! command -v unzip >/dev/null || ! command -v curl >/dev/null; then
  red_echo "📦 Installing unzip and curl (required)"
  aptwaitand_run "apt-get update -y"
  aptwaitand_run "apt-get install -y unzip curl"
else
  red_echo "⏭️ Skipping unzip and curl install — already present"
fi
writemarker unzipinstalled

-------------------------

System update and base packages

-------------------------
if ! markerexists systemupdated; then
  red_echo "📦 Updating system packages and installing base deps"
  aptwaitand_run "apt-get update -y"
  aptwaitand_run "apt-get upgrade -y"
  aptwaitand_run "apt-get install -y ca-certificates gnupg lsb-release wget git build-essential jq lsof software-properties-common gpg"
  writemarker systemupdated
else
  red_echo "⏭️ Skipping system update — already marked complete"
fi

-------------------------

Docker install (if missing)

-------------------------
if ! command -v docker >/dev/null; then
  red_echo "📦 Installing Docker (docker-ce, containerd)"
  aptwaitand_run "apt-get remove -y docker docker-engine docker.io containerd runc || true"
  sudo install -m 0755 -d /etc/apt/keyrings || true
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list
  aptwaitand_run "apt-get update -y"
  aptwaitand_run "apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin"
  sudo systemctl enable --now docker || true
else
  red_echo "⏭️ Skipping Docker install — already present"
fi
writemarker dockerinstalled

-------------------------

Bun install (if missing)

-------------------------
if ! command -v bun >/dev/null; then
  red_echo "📦 Installing Bun (JavaScript runtime/package manager)"
  curl -fsSL https://bun.sh/install | bash || true
  if [ -d "$HOME/.bun/bin" ]; then
    cat > "$BUN_PROFILE" <<'EOF'
export BUN_INSTALL="$HOME/.bun"
export PATH="$HOME/.bun/bin:$PATH"
EOF
    chmod 644 "$BUN_PROFILE" || true
    export BUN_INSTALL="$HOME/.bun"
    export PATH="$HOME/.bun/bin:$PATH"
  fi
else
  red_echo "⏭️ Skipping Bun install — already present"
fi
writemarker buninstalled

-------------------------

Clone node repository and install deps

-------------------------
if [ ! -d "$NODE_PATH" ]; then
  redecho "🌱 Cloning node repository into $NODEPATH (branch: testnet)"
  git clone -b testnet https://github.com/kynesyslabs/node.git "$NODE_PATH" || {
    red_echo "❌ Git clone failed; please check network and repo URL"
  }
  if [ -d "$NODE_PATH" ]; then
    pushd "$NODE_PATH" >/dev/null
    bun install || npm install || true
    popd >/dev/null
  fi
else
  redecho "⏭️ Skipping node clone — $NODEPATH already exists"
fi
writemarker nodecloned

-------------------------

run-wrapper script

-------------------------
mkdir -p "$NODE_PATH"
cat > "$NODE_PATH/run-wrapper.sh" <<'EOF'

!/bin/bash

Expose Bun and sane PATH for systemd service
export BUN_INSTALL=/root/.bun
export PATH=/root/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
cd /root/node
exec /bin/bash ./run
EOF
chmod +x "$NODE_PATH/run-wrapper.sh" || true
writemarker runwrapper_created

-------------------------

Create systemd unit

-------------------------
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
Environment=PATH=/root/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=BUN_INSTALL=/root/.bun

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now demos-node.service || true
writemarker systemdinstalled

-------------------------

Wait for key generation

-------------------------
if [ -f "$NODEPATH/publickey" ] && [ -f "$NODEPATH/privatekey" ]; then
  chmod 600 "$NODE_PATH/privatekey" || true
  writemarker keysgenerated
  red_echo "✅ Node keys already present"
else
  red_echo "⏳ Waiting for node to generate keys (up to 60s)..."
  for i in {1..60}; do
    [ -f "$NODEPATH/publickey" ] && [ -f "$NODEPATH/privatekey" ] && break
    sleep 1
  done
  if [ -f "$NODEPATH/publickey" ] && [ -f "$NODEPATH/privatekey" ]; then
    chmod 600 "$NODE_PATH/privatekey" || true
    writemarker keysgenerated
    red_echo "✅ Keys detected and secured"
  else
    red_echo "⚠️ Keys not found after wait; continue and check node logs later"
  fi
fi

-------------------------

Configure .env and peerlist

-------------------------
if ! markerexists nodeconfigured; then
  PUBLIC_IP="$(curl -s --max-time 5 https://api.ipify.org || echo 127.0.0.1)"
  log "Detected public IP: $PUBLIC_IP"
  redecho "🌐 Using public IP: $PUBLICIP for .env and peerlist"
  echo "EXPOSEDURL=http://$PUBLICIP:53550" > "$NODE_PATH/.env"
  if [ -f "$NODE_PATH/publickey" ]; then
    PUBKEY="$(tr -d '\r\n' < "$NODE_PATH/publickey")"
    printf '{"%s":"http://%s:53550"}\n' "$PUBKEY" "$PUBLICIP" > "$NODEPATH/demos_peerlist.json"
  fi
  writemarker nodeconfigured
else
  red_echo "⏭️ Skipping .env and peerlist configuration — already configured"
fi

-------------------------

Port cleanup for 5332

-------------------------
if command -v lsof >/dev/null && lsof -i :5332 &>/dev/null; then
  red_echo "🧹 Freeing port 5332 (in use) to avoid conflicts"
  lsof -t -i :5332 | xargs -r kill || true
  sleep 2
fi

-------------------------

Restart service and verify

-------------------------
systemctl restart demos-node.service || true
sleep 2
if systemctl is-active --quiet demos-node.service; then
  red_echo "✅ Node service is active"
else
  red_echo "⚠️ Node service is not active — check logs: journalctl -u demos-node.service -n 200 --no-pager"
fi

-------------------------

Helper scripts (local and global)

-------------------------

restart script
cat > /root/restartdemosnode.sh <<'EOF'

!/bin/bash

Restarts demos-node service and prints status
systemctl restart demos-node.service
systemctl status demos-node.service --no-pager -l
EOF
chmod +x /root/restartdemosnode.sh || true

backup keys script
cat > /root/backupdemoskeys.sh <<'EOF'

!/bin/bash

Copies node keys to ~/demos-keys with 600 perms for privatekey
mkdir -p ~/demos-keys
cp /root/node/publickey ~/demos-keys/publickey 2>/dev/null || true
cp /root/node/privatekey ~/demos-keys/privatekey 2>/dev/null || true
chmod 600 ~/demos-keys/privatekey 2>/dev/null || true
ls -l ~/demos-keys || true
EOF
chmod +x /root/backupdemoskeys.sh || true

stop script (one-step stop)
cat > /root/stopdemosnode.sh <<'EOF'

!/bin/bash
set -euo pipefail

Stop and disable systemd service
sudo systemctl stop demos-node.service || true
sudo systemctl disable --now demos-node.service || true

Kill any processes referencing /root/node
pgrep -f "/root/node" | xargs -r sudo kill -9 || true
pkill -f "/root/node/run" || true

Free ports typically used by node
sudo lsof -ti :5332 | xargs -r sudo kill -9 || true
sudo lsof -ti :53550 | xargs -r sudo kill -9 || true

Stop Docker containers containing 'demos' in their name
sudo docker ps -q --filter "name=demos" | xargs -r sudo docker stop || true

Remove common pid/lock files
sudo rm -f /run/demos-node.pid /var/run/demos-node.pid /root/.demosnodesetup/installer.lock || true

Show final service status
sudo systemctl status demos-node.service --no-pager -l || true
echo "Stop sequence complete"
EOF
chmod +x /root/stopdemosnode.sh || true

Install global helper wrappers in /usr/local/bin
mkdir -p "$GLOBAL_BIN"
cat > "$GLOBALBIN/restartdemos_node" <<'EOF'

!/bin/bash
exec /root/restartdemosnode.sh "$@"
EOF
chmod +x "$GLOBALBIN/restartdemos_node" || true

cat > "$GLOBALBIN/backupdemos_keys" <<'EOF'

!/bin/bash
exec /root/backupdemoskeys.sh "$@"
EOF
chmod +x "$GLOBALBIN/backupdemos_keys" || true

cat > "$GLOBALBIN/stopdemos_node" <<'EOF'

!/bin/bash
exec /root/stopdemosnode.sh "$@"
EOF
chmod +x "$GLOBALBIN/stopdemos_node" || true

writemarker helperscreated

-------------------------

Final marker and messages

-------------------------
writemarker installcomplete
red_echo "🎉 Install complete. Helper commands (available globally):"
redecho "  restartdemos_node   - restart node and view status"
redecho "  backupdemos_keys    - copy keys to ~/demos-keys (check perms)"
redecho "  stopdemos_node      - stop service, kill processes, free ports (one-step)"
redecho "ℹ️ Local helper scripts also available in /root/: restartdemosnode.sh, backupdemoskeys.sh, stopdemos_node.sh"
redecho "ℹ️ Marker files located in $MARKERDIR. Remove specific marker files to re-run particular steps."

End of script
`
