#!/usr/bin/env bash
# =============================================================================
# migrate-server.sh — copy THIS server onto a new, empty VPS. Passwords only.
#
#   Run as root on the server you are copying FROM:   bash migrate-server.sh
#
# Result: a complete, separate copy (app, .env, cookies, MongoDB, Redis).
# Based on the RackNerd rsync method, with the problems we hit fixed:
#   - MongoDB/Redis are stopped briefly for a final sync, so the copy is safe.
#   - The new server keeps its own root password, the whole time.
#   - Provider-specific files (network, DNS, SSH, kernel) are not copied.
#   - LOCAL_NETWORKS is set to the new IP; Madrasati is pinned if DNS can't find it.
#   - The app does not start on the new server unless you say so.
# Safe to run again if the connection drops: rsync continues where it stopped.
# =============================================================================
set -Eeuo pipefail

APP_DIR=/home/desktop/Web-App
MADRASATI_HOST=schools.madrasati.sa
MADRASATI_PIN=20.203.8.77

c_red=$'\e[31m' c_grn=$'\e[32m' c_ylw=$'\e[33m' c_cyn=$'\e[36m' c_off=$'\e[0m'
info() { printf '%s[i]%s %s\n' "$c_cyn" "$c_off" "$*"; }
ok()   { printf '%s[ok]%s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_ylw" "$c_off" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

confirm() { local r; read -r -p "$1 [y/N]: " r; [[ $r =~ ^[Yy]$ ]]; }

write_excludes() {  # file
  cat >"$1" <<'EOF'
# System-specific files: the new server keeps its own
/etc/fstab
/etc/network/*
/etc/netplan/*
/etc/NetworkManager/*
/etc/systemd/network/*
/etc/systemd/resolved.conf
/etc/systemd/resolved.conf.d/*
/etc/resolv.conf
/etc/hostname
/etc/hosts
/etc/machine-id
/var/lib/dbus/machine-id
/etc/ssh/*
/etc/default/*
/etc/udev/*
/etc/iptables/*
/etc/iptables.rules
# Same-provider fix: these can carry the source's IP and bring it up on the new server
/etc/cloud/*
/var/lib/dhcp/*
/var/lib/NetworkManager/*
/boot/*
/usr/lib/modules/*
/usr/lib/firmware/*
/lib/modules/*
/lib/firmware/*
/var/lib/cloud/*
/swapfile
/swap.img
# Copied last, keeping the new server's root password
/etc/shadow
/etc/shadow-
/root/.ssh/*
# Live or temporary
/proc/*
/sys/*
/dev/*
/run/*
/tmp/*
/mnt/*
/media/*
/lost+found
/var/run/*
/var/lock/*
/var/tmp/*
/var/crash/*
/var/log/*/*
/var/cache/apt/*
/var/lib/apt/lists/*
# Not needed, and very large
/home/*/thinclient_drives
/home/*/.vscode-server
/home/*/.npm
/root/.cache
/home/desktop/Web-App/resources/teams-runtime/*
/home/desktop/Web-App/dist copy
# Snaps (e.g. chromium): copy the snap files and their state, but not the
# mounted contents under /snap/<name>/<revision>, which are mounted again at boot
/snap/*/*/*
# Keep Puppeteer's Chrome (~/.cache/puppeteer), skip the rest of the cache
+ /home/*/.cache/
+ /home/*/.cache/puppeteer/***
- /home/*/.cache/*
# Fleet tool secrets and this script's logs
/etc/tplus-fleet
/var/lib/tplus-fleet
/var/log/tplus-fleet
/root/migrate-*.log
EOF
}

# Keeps the new server's own root line; every other account comes from the source.
merge_shadow_script() {
  cat <<'EOS'
set -e
umask 077
awk -F: 'NR==FNR { if ($1=="root") r=$0; next } $1=="root" && r!="" { print r; next } { print }' \
  /etc/shadow /root/.migrate-shadow >/etc/shadow.migrate-new
[ -s /etc/shadow.migrate-new ] && grep -q '^root:' /etc/shadow.migrate-new
chown root:shadow /etc/shadow.migrate-new
chmod 640 /etc/shadow.migrate-new
mv /etc/shadow.migrate-new /etc/shadow
rm -f /root/.migrate-shadow
EOS
}

remote() { sshpass -e ssh "${SSH_OPTS[@]}" -p "$PORT" "root@$IP" "$@"; }

run_rsync() {  # extra-options... -- sources...
  local opts=() rc=0
  while [[ $1 != -- ]]; do opts+=("$1"); shift; done; shift
  rsync -aHAXR --numeric-ids --partial --info=progress2 --stats "${opts[@]}" \
    -e "$RSH" "$@" "root@$IP:/" 2> >(tee -a "$LOG" >&2) | tee -a "$LOG" || rc=$?
  case $rc in
    0)     ;;
    23|24) warn "rsync code $rc: a few files were skipped or changed during the copy. See $LOG" ;;
    *)     die "rsync failed (code $rc). See $LOG. Run this script again to continue." ;;
  esac
}

restart_containers() {
  if [[ ${DB_STOPPED:-0} == 1 ]]; then
    info "Starting the containers on this server again..."
    # shellcheck disable=SC2086
    docker start $RUNNING_CONTAINERS >/dev/null || warn "Could not restart: $RUNNING_CONTAINERS"
    DB_STOPPED=0
  fi
}

can_reach() { timeout 10 bash -c "</dev/tcp/$IP/$PORT" 2>/dev/null; }

cleanup() {
  restart_containers
  if [[ -n ${GW_ROUTE:-} ]]; then ip route del "$GW_ROUTE/32" 2>/dev/null || true; fi
  [[ -n ${WORK:-} ]] && rm -rf "$WORK"
}

# Starts the app with pm2, the same way as the app's own "pnpm pm2:start", plus
# a virtual screen for Chrome and a pm2 boot service.
start_app_with_pm2() {
  local node node_dir pm2
  node=$(remote "ls -d /home/desktop/.nvm/versions/node/*/bin/node 2>/dev/null | sort -V | tail -1")
  [[ -n $node ]] || { warn "Node not found for user desktop; the app was not started."; return 0; }
  node_dir=${node%/node}
  pm2=$(remote "ls -d $node_dir/pm2 /home/desktop/.local/share/pnpm/pm2 $APP_DIR/node_modules/.bin/pm2 2>/dev/null | head -1")
  [[ -n $pm2 ]] || { warn "pm2 not found for user desktop; the app was not started."; return 0; }

  info "Starting the virtual screen..."
  remote "command -v Xvfb >/dev/null && command -v xdotool >/dev/null ||
      (apt-get update -qq && apt-get install -y -qq xvfb xdotool)
    cat >/etc/systemd/system/tplus-display.service <<'EOF'
[Unit]
Description=Virtual screen :99 for Teams browsers
After=network.target

[Service]
User=desktop
ExecStart=/usr/bin/Xvfb :99 -screen 0 1920x1080x24 -nolisten tcp
ExecStartPost=/bin/sh -c 'sleep 2; DISPLAY=:99 xfwm4 --compositor=off >/dev/null 2>&1 &'
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    systemctl disable --now tplus-app >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/tplus-app.service
    systemctl daemon-reload
    systemctl enable --now tplus-display >/dev/null 2>&1"

  info "Starting the app with pm2..."
  remote "su - desktop -c 'export PATH=$node_dir:\$PATH; cd $APP_DIR
    $pm2 delete tplus-auto-prepare >/dev/null 2>&1
    DISPLAY=:99 XAUTHORITY=\$HOME/.Xauthority NODE_ENV=production NODE_OPTIONS=--dns-result-order=ipv4first \
      $pm2 start dist/src/main.js --name tplus-auto-prepare --update-env
    $pm2 save --force'"

  info "Setting pm2 to start on boot..."
  remote "env PATH=$node_dir:\$PATH $pm2 startup systemd -u desktop --hp /home/desktop >/dev/null
    mkdir -p /etc/systemd/system/pm2-desktop.service.d
    printf '[Unit]\nAfter=tplus-display.service docker.service\nWants=tplus-display.service\n' \
      >/etc/systemd/system/pm2-desktop.service.d/display.conf
    systemctl daemon-reload"

  sleep 20
  if remote "ss -ltn | grep -q ':3009 '"; then
    ok "App is running on $IP with pm2 and starts on boot. Check as desktop: pm2 status"
  else
    warn "App is not answering yet. As desktop on $IP run: pm2 logs tplus-auto-prepare --lines 50"
  fi
}

main() {
  [[ $EUID -eq 0 ]] || die "Run as root."

  local missing=() t
  for t in rsync ssh sshpass awk; do command -v "$t" >/dev/null || missing+=("$t"); done
  if ((${#missing[@]})); then
    info "Installing: ${missing[*]}"
    apt-get update -qq
    apt-get install -y -qq rsync openssh-client sshpass gawk >/dev/null
  fi

  echo
  echo "This copies THIS server ($(hostname)) onto a new, empty VPS."
  echo "Everything on the new VPS will be overwritten."
  echo
  read -r -p "New server IP: " IP
  [[ $IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "That is not an IP address."
  [[ " $(hostname -I) " != *" $IP "* ]] || die "$IP is this server. Enter the NEW server's IP."
  read -r -p "SSH port [22]: " PORT; PORT=${PORT:-22}
  [[ $PORT =~ ^[0-9]+$ ]] || die "Bad port."
  read -r -s -p "Root password of $IP: " SSHPASS; echo
  [[ -n $SSHPASS ]] || die "Empty password."
  export SSHPASS

  WORK=$(mktemp -d /tmp/migrate.XXXXXX)
  trap cleanup EXIT
  local excludes="$WORK/excludes.txt"
  write_excludes "$excludes"
  LOG="/root/migrate-$IP-$(date +%Y%m%d-%H%M%S).log"
  local ssh_common="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$WORK/known_hosts -o ConnectTimeout=10 -o ServerAliveInterval=30 -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive"
  # shellcheck disable=SC2206
  SSH_OPTS=($ssh_common)

  info "Checking the new server..."
  if ! can_reach; then
    # Same provider: the IP is in our own network block, so it is tried directly
    # on the local network, which the provider may block. Go through the gateway.
    local gw
    gw=$(ip route show default | awk '{print $3; exit}')
    if ! ip route get "$IP" | grep -q ' via ' && [[ -n $gw && $gw != "$IP" ]]; then
      info "$IP is on this server's local network. Trying through the gateway $gw..."
      ip route add "$IP/32" via "$gw" && GW_ROUTE=$IP
    fi
    can_reach || die "Cannot reach $IP on port $PORT (network problem, not the password). Check: ip route get $IP"
    ok "Reached $IP through the gateway (temporary route, removed at the end)."
  fi
  RSH="sshpass -e ssh -p $PORT $ssh_common"
  remote true || die "Cannot log in to root@$IP with that password."
  ok "Password login works."

  local os_here os_new
  # shellcheck disable=SC1091
  os_here=$(. /etc/os-release; echo "$ID $VERSION_ID")
  os_new=$(remote '. /etc/os-release; echo "$ID $VERSION_ID"')
  [[ $os_here == "$os_new" ]] || die "OS mismatch: this server is '$os_here', new is '$os_new'. Reinstall it with $os_here."
  ok "Same OS on both: $os_new"

  local used avail
  used=$(df --output=used -B1G / | tail -1 | tr -d ' ')
  avail=$(remote "df --output=avail -B1G / | tail -1 | tr -d ' '")
  info "Disk: this server uses ${used} GB, the new one has ${avail} GB free."
  if (( used >= avail )); then
    warn "The new server may not have enough space (exclusions make the real copy smaller)."
    confirm "Continue anyway?" || die "Aborted."
  fi

  if [[ $(remote '[ -d /home/desktop ] && echo used || echo fresh') != fresh ]]; then
    warn "$IP already has /home/desktop: it is not empty (or this is a re-run)."
    confirm "Overwrite it?" || die "Aborted."
  fi

  RUNNING_CONTAINERS=""
  command -v docker >/dev/null && RUNNING_CONTAINERS=$(docker ps -q | xargs)
  local safe_db=yes
  if [[ -n $RUNNING_CONTAINERS ]]; then
    echo
    echo "MongoDB/Redis must stop for a short time at the END of the copy for a safe database copy."
    echo "They start again by themselves right after."
    confirm "Stop them briefly on this server?" || safe_db=no
    [[ $safe_db == yes ]] || warn "The database copy may be inconsistent."
  fi

  local start_app=no
  echo
  warn "If the app runs on both servers, both handle the same teachers."
  confirm "Start the app on the new server when the copy is done?" && start_app=yes

  echo
  echo "  From : $(hostname)"
  echo "  To   : $IP  (will be overwritten and rebooted)"
  echo "  Start app there: $start_app"
  local again; read -r -p "Type the new server's IP again to start: " again
  [[ $again == "$IP" ]] || die "IP did not match. Nothing was changed."

  remote 'command -v rsync >/dev/null || (apt-get update -qq && apt-get install -y -qq rsync)'

  local started=$SECONDS
  info "Copying files. Log: $LOG"
  run_rsync --exclude-from="$excludes" -- /
  ok "Files copied in $(( (SECONDS - started) / 60 )) min."

  if [[ -n $RUNNING_CONTAINERS && $safe_db == yes ]]; then
    info "Stopping containers for the final database sync..."
    DB_STOPPED=1
    # shellcheck disable=SC2086
    docker stop $RUNNING_CONTAINERS >/dev/null
    run_rsync --delete -- /var/lib/docker/volumes/
    restart_containers
    ok "Database copied."
  fi

  info "Merging user accounts (the new server keeps its root password)..."
  remote 'umask 077; cat >/root/.migrate-shadow' </etc/shadow
  merge_shadow_script | remote 'bash -s'
  ok "Accounts merged."

  info "Adjusting the new server..."
  # Snap mount units whose snap file is missing make snapd fail at boot.
  remote 'for u in /etc/systemd/system/snap-*.mount; do
      [ -e "$u" ] || continue
      f=$(sed -n "s/^What=//p" "$u")
      if [ -n "$f" ] && [ ! -e "$f" ]; then rm -f "$u" /etc/systemd/system/*/"$(basename "$u")"; fi
    done'
  # Nothing may auto-start until the settings below are right.
  remote 'rm -f /etc/systemd/system/multi-user.target.wants/tplus-app.service \
                /etc/systemd/system/multi-user.target.wants/pm2-desktop.service'
  remote "[ -f '$APP_DIR/.env' ] || exit 0
    cd '$APP_DIR'
    if grep -q '^LOCAL_NETWORKS=' .env; then sed -i 's|^LOCAL_NETWORKS=.*|LOCAL_NETWORKS=$IP|' .env
    else echo 'LOCAL_NETWORKS=$IP' >>.env; fi"
  ok "LOCAL_NETWORKS set to $IP"

  info "Rebooting $IP..."
  remote 'systemctl reboot' >/dev/null 2>&1 || true
  sleep 20
  local up=no i
  for ((i = 0; i < 60; i++)); do
    if remote true >/dev/null 2>&1; then up=yes; break; fi
    sleep 5
  done
  [[ $up == yes ]] || die "$IP did not come back in 5 minutes. Check the provider's console."
  ok "New server is back, and its own root password still works."

  if ! remote "getent hosts $MADRASATI_HOST >/dev/null"; then
    remote "echo '$MADRASATI_PIN $MADRASATI_HOST' >>/etc/hosts"
    ok "Pinned $MADRASATI_HOST to $MADRASATI_PIN (its DNS only answers Saudi clients)."
  fi

  if command -v snap >/dev/null && snap list chromium >/dev/null 2>&1; then
    if remote 'snap list chromium' >/dev/null 2>&1; then
      ok "chromium snap is installed on $IP."
    else
      warn "chromium snap is not working on $IP. There run: systemctl restart snapd; snap list"
    fi
  fi

  if [[ $start_app == yes ]]; then
    start_app_with_pm2
  else
    info "App not started on $IP."
  fi

  echo
  ok "Migration finished: $IP"
  info "Log: $LOG"
  info "Users copied from this server keep their passwords (including desktop)."
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
