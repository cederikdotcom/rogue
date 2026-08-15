#!/usr/bin/env bash
# Provision a fresh rogue-web host. Runs as root on the new server.
set -euo pipefail

DOMAIN=rogue.cederik.com
GAME_USER=rogue
REPO=https://github.com/cederikdotcom/rogue.git
APP=/opt/rogue

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -yq gcc make libncurses-dev git golang-go curl debian-keyring debian-archive-keyring apt-transport-https

# Caddy repo + install
curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt > /etc/apt/sources.list.d/caddy-stable.list
apt-get update -q
apt-get install -yq caddy

# Non-root game user, no interactive login
id -u $GAME_USER >/dev/null 2>&1 || useradd --system --create-home --home-dir /home/$GAME_USER --shell /usr/sbin/nologin $GAME_USER

# App dir owned by the game user
mkdir -p $APP
chown $GAME_USER:$GAME_USER $APP

# Clone + build as the game user
sudo -u $GAME_USER bash -euc "
  cd $APP
  rm -rf src
  git clone -q $REPO src
  cd src
  ./configure -q
  make CFLAGS='-g -O2 -DNO_SHELL_ESCAPE' >/dev/null
  cd web
  go build -o rogue-web .
  mkdir -p $APP/saves
"

# systemd service running as the non-root user, hardened
cat > /etc/systemd/system/rogue-web.service <<EOF
[Unit]
Description=Rogue in the browser
After=network.target

[Service]
User=$GAME_USER
Group=$GAME_USER
WorkingDirectory=$APP/src
ExecStart=$APP/src/web/rogue-web -addr 127.0.0.1:8080 -rogue $APP/src/rogue -static $APP/src/web/static -saves $APP/saves
Restart=on-failure
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$APP
PrivateTmp=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF

# Caddy vhost
cat > /etc/caddy/Caddyfile <<EOF
$DOMAIN {
	reverse_proxy 127.0.0.1:8080
}
EOF

systemctl daemon-reload
systemctl enable --now rogue-web
systemctl restart caddy
sleep 2
echo "rogue-web: $(systemctl is-active rogue-web)  caddy: $(systemctl is-active caddy)"
echo "runs as: $(ps -o user= -C rogue-web | head -1)"
echo "PROVISION-DONE"
