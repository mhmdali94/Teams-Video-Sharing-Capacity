#!/usr/bin/env bash
# =============================================================================
# tplus-fleet v1 — manage Teams worker VPSes from the MAIN server.
#
#   sudo ./tplus-fleet.sh init          one-time setup on the main server
#   sudo ./tplus-fleet.sh               interactive menu
#   sudo ./tplus-fleet.sh health-once   one health pass (used by the menu)
#   sudo ./tplus-fleet.sh health-loop   endless health loop (used by systemd)
#
# What it does
#   - Adds a fresh VPS (IP + root password) and clones a template server onto it
#     with rsync (RackNerd method), with these fixes over the plain method:
#       * Databases (Docker/containerd data) are NOT copied: workers use main's DB.
#       * Secrets are NOT copied: .env, cookies/, fleet secrets, SSH keys, history.
#       * Junk is NOT copied: snaps, caches, VS Code server, screenshots, dist copy.
#       * Kernel modules under /usr/lib (merged /usr on Ubuntu) are not copied.
#       * Hard links, ACLs and xattrs are preserved (-HAX), numeric ids kept.
#       * Host keys are pinned (accept-new), not StrictHostKeyChecking=no.
#       * Root password of the new VPS is restored after the clone.
#   - Keeps a registry of servers, their specs and max teachers.
#   - Stores VPS passwords encrypted; logs in with an SSH key afterwards, and
#     re-installs the key with the stored password if it stops working.
#   - Health-checks every server (reachable, CPU steal, RAM, Chrome sessions,
#     app running, paid time left) and syncs the status to MongoDB (optional).
#
# Runs only on the main server: init records this machine's machine-id and the
# script refuses to run anywhere else (clones get a different machine-id).
# =============================================================================
set -Eeuo pipefail

FLEET_ETC=/etc/tplus-fleet
FLEET_VAR=/var/lib/tplus-fleet
FLEET_LOG=/var/log/tplus-fleet
CONF="$FLEET_ETC/fleet.conf"
MASTER_KEY="$FLEET_ETC/master.key"
SSH_KEY="$FLEET_ETC/ssh/id_ed25519"
EXCLUDES="$FLEET_ETC/clone-excludes.txt"
WORKER_ENV="$FLEET_ETC/worker.env"
REGISTRY="$FLEET_VAR/servers.tsv"
SECRETS="$FLEET_VAR/secrets"
KNOWN_HOSTS="$FLEET_VAR/known_hosts"
LOCK="$FLEET_VAR/.lock"

REG_HEADER=$'name\tip\tport\trole\tstatus\tmax_teachers\tcpus\tram_mb\tsessions\tsteal\tapp_up\tcreated_at\tpaid_until\tlast_seen\tfails'
# Field numbers in the registry (1-based, used by awk).
F_NAME=1 F_IP=2 F_PORT=3 F_ROLE=4 F_STATUS=5 F_MAX=6 F_CPUS=7 F_RAM=8
F_SESS=9 F_STEAL=10 F_APP=11 F_CREATED=12 F_PAID=13 F_SEEN=14 F_FAILS=15

# ----------------------------------------------------------------------------- output
c_red=$'\e[31m' c_grn=$'\e[32m' c_ylw=$'\e[33m' c_cyn=$'\e[36m' c_off=$'\e[0m'
info() { printf '%s[i]%s %s\n' "$c_cyn" "$c_off" "$*"; }
ok()   { printf '%s[ok]%s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_ylw" "$c_off" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }
log()  { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$FLEET_LOG/fleet.log"; }

ask() {  # ask "Prompt" default -> echoes answer
  local reply
  read -r -p "$1${2:+ [$2]}: " reply
  printf '%s' "${reply:-${2:-}}"
}
confirm() {  # confirm "Question" -> 0 if yes
  local reply
  read -r -p "$1 [y/N]: " reply
  [[ $reply =~ ^[Yy]$ ]]
}
ask_secret() {  # ask_secret "Prompt" -> echoes value (asked twice)
  local a b
  while true; do
    read -r -s -p "$1: " a; echo >&2
    read -r -s -p "Repeat: " b; echo >&2
    [[ -n $a && $a == "$b" ]] && { printf '%s' "$a"; return; }
    warn "Empty or not matching, try again."
  done
}

valid_name() { [[ $1 =~ ^[a-z0-9][a-z0-9-]{1,29}$ ]]; }
valid_ip()   { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
valid_int()  { [[ $1 =~ ^[0-9]+$ ]]; }
now()        { date +%s; }

# ----------------------------------------------------------------------------- guards
require_root() { [[ $EUID -eq 0 ]] || die "Run as root (sudo)."; }

require_main() {
  [[ -f $CONF ]] || die "Not initialised. Run: sudo $0 init"
  # shellcheck source=/dev/null
  source "$CONF"
  [[ ${MAIN_MACHINE_ID:-} == "$(cat /etc/machine-id)" ]] \
    || die "This is not the main server (machine-id differs). Refusing to run."
}

require_tools() {
  local missing=() t
  for t in rsync ssh ssh-keygen sshpass openssl flock awk; do
    command -v "$t" >/dev/null || missing+=("$t")
  done
  ((${#missing[@]} == 0)) && return
  warn "Missing tools: ${missing[*]}"
  confirm "Install them with apt now?" || die "Cannot continue without them."
  apt-get update -qq
  apt-get install -y -qq rsync openssh-client sshpass openssl util-linux gawk
}

# ----------------------------------------------------------------------------- init
write_default_excludes() {
  cat >"$EXCLUDES" <<'EOF'
# ---- RackNerd base list (system-specific files) ----
/etc/fstab
/etc/sysconfig/network-scripts/*
/etc/systemd/network/*
/etc/network/*
/etc/netplan/*
/etc/NetworkManager/*
/etc/resolv.conf
# Fix: DNS settings are provider-specific (copied ones broke name resolution)
/etc/systemd/resolved.conf
/etc/systemd/resolved.conf.d/*
/etc/hostname
/etc/hosts
/etc/machine-id
/var/lib/dbus/machine-id
/proc/*
/tmp/*
/sys/*
/dev/*
/mnt/*
/boot/*
/etc/default/*
/run/*
/var/run/*
/var/lock/*
/media/*
/lost+found
/swapfile
/swap.img
/etc/sysconfig/iptables
/etc/iptables/rules.v4
/etc/iptables.rules
/var/lib/iptables/rules-save
/etc/ssh/*
/var/crash/*
/var/log/*/*
/var/cache/apt/*
/var/lib/apt/lists/*
/var/lib/cloud/*
/etc/udev/*
/lib/modules/*
/lib/firmware/*
# Ubuntu has merged /usr: the real kernel files live here
/usr/lib/modules/*
/usr/lib/firmware/*

# ---- Fix: never copy databases (workers use the main server's DB) ----
/var/lib/docker/*
/var/lib/containerd/*

# ---- Fix: never copy secrets ----
/etc/tplus-fleet
/var/lib/tplus-fleet
/var/log/tplus-fleet
/root/.ssh/*
/home/*/.ssh/*
/root/.bash_history
/home/*/.bash_history
/root/excludedfiles.txt
/root/.tplus-fleet-excludes.txt
/home/desktop/Web-App/.env
/home/desktop/Web-App/.env.local
/home/desktop/Web-App/.env.production
/home/desktop/Web-App/cookies/*
/home/*/.copilot

# ---- Fix: don't copy what a worker doesn't need ----
/snap/*
/var/snap/*
/var/lib/snapd/*
/home/*/snap
/home/*/thinclient_drives
/home/*/.vscode-server
# Keep Puppeteer's Chrome for Testing (lives in ~/.cache/puppeteer), skip the rest of the cache
+ /home/*/.cache/
+ /home/*/.cache/puppeteer/***
- /home/*/.cache/*
/home/*/.npm
/root/.cache
/home/desktop/Web-App/resources/teams-runtime/*
/home/desktop/Web-App/dist copy
/var/tmp/*
EOF
}

cmd_init() {
  require_root
  require_tools
  if [[ -f $CONF ]]; then
    warn "Already initialised ($CONF)."
    confirm "Re-run init? Keys and registry are kept" || exit 0
  fi
  echo "This marks THIS machine ($(hostname)) as the fleet MAIN server."
  confirm "Is this the main server?" || die "Aborted."

  install -d -m 700 "$FLEET_ETC" "$FLEET_ETC/ssh" "$FLEET_VAR" "$SECRETS"
  install -d -m 750 "$FLEET_LOG"
  [[ -f $REGISTRY ]] || { printf '%s\n' "$REG_HEADER" >"$REGISTRY"; chmod 600 "$REGISTRY"; }
  touch "$KNOWN_HOSTS"; chmod 600 "$KNOWN_HOSTS"

  if [[ ! -f $MASTER_KEY ]]; then
    (umask 077; openssl rand -base64 48 >"$MASTER_KEY")
    ok "Created master key $MASTER_KEY (back it up offline; without it stored passwords are lost)."
  fi
  if [[ ! -f $SSH_KEY ]]; then
    ssh-keygen -q -t ed25519 -N '' -C "tplus-fleet@$(hostname)" -f "$SSH_KEY"
    ok "Created fleet SSH key $SSH_KEY"
  fi
  [[ -f $EXCLUDES ]] || { write_default_excludes; ok "Wrote clone exclude list $EXCLUDES"; }
  write_default_methods

  if [[ ! -f $CONF ]]; then
    cat >"$CONF" <<EOF
# tplus-fleet configuration (sourced by bash)
MAIN_MACHINE_ID="$(cat /etc/machine-id)"

# Seconds between health passes in health-loop
HEALTH_INTERVAL=60
# Failed checks in a row before a server is marked unreachable
FAILS_BEFORE_DOWN=3
# Warn when less than this many minutes of paid time are left
PAID_WARN_MIN=10
# Default paid hours for a new server
DEFAULT_PAID_HOURS=1

# Capacity suggestion per teacher (from test VPS measurements)
CORES_PER_TEACHER=1.0
RAM_MB_PER_TEACHER=1600
RAM_MB_RESERVED=2048

# Optional MongoDB sync of the registry (collection: fleet_servers).
# The URI is NOT read from the app's .env: fill it here yourself.
MONGO_SYNC=0
MONGO_CMD="docker exec -i mongo mongosh"
MONGO_URI=""

# Ask to open MongoDB/Redis on the main firewall (ufw) for each new worker
FIREWALL_PORTS="27017 6379"

# Worker settings
# Migration method offered first (file name in methods/ without .sh)
DEFAULT_METHOD=rsync-full
APP_DIR=/home/desktop/Web-App
# Containers that must NOT run on a worker (it uses main's DB/Redis)
WORKER_DISABLE_CONTAINERS="mongodb my-redis"
# Names the worker must be able to resolve
DNS_CHECK_HOSTS="schools.madrasati.sa login.microsoftonline.com teams.microsoft.com"
# Fixed /etc/hosts entries ("IP name", separated by ;). Madrasati's DNS only
# answers Saudi clients, so servers abroad get ENOTFOUND without this.
HOSTS_PINS="20.203.8.77 schools.madrasati.sa"
EOF
    chmod 600 "$CONF"
    ok "Wrote config $CONF"
  fi
  log "init on $(hostname)"
  echo
  info "Optional: put the worker app config in $WORKER_ENV (chmod 600)."
  info "It is copied to each new worker as Web-App/.env, pointing to the main DB/Redis."
  ok "Init done. Run: sudo $0"
}

# ----------------------------------------------------------------------------- registry
with_lock() { ( flock -w 30 9 || die "Registry is locked."; "$@" ) 9>"$LOCK"; }

reg_exists() { awk -F'\t' -v n="$1" 'NR>1 && $1==n {f=1} END {exit !f}' "$REGISTRY"; }
reg_get()    { awk -F'\t' -v n="$1" -v f="$2" 'NR>1 && $1==n {print $f}' "$REGISTRY"; }
reg_names()  { awk -F'\t' -v r="${1:-}" 'NR>1 && (r=="" || $4==r) {print $1}' "$REGISTRY"; }

_reg_set() {  # name field value [field value ...]
  local name=$1; shift
  local tmp; tmp=$(mktemp "$FLEET_VAR/.reg.XXXX")
  awk -F'\t' -v OFS='\t' -v n="$name" -v kv="$*" '
    BEGIN { c = split(kv, a, " "); for (i = 1; i < c; i += 2) set[a[i]] = a[i+1] }
    NR>1 && $1==n { for (k in set) $k = set[k] }
    { print }' "$REGISTRY" >"$tmp"
  chmod 600 "$tmp"; mv "$tmp" "$REGISTRY"
}
reg_set() { with_lock _reg_set "$@"; }

_reg_add() { printf '%s\n' "$1" >>"$REGISTRY"; }
reg_add() { with_lock _reg_add "$1"; }

_reg_del() {
  local tmp; tmp=$(mktemp "$FLEET_VAR/.reg.XXXX")
  awk -F'\t' -v n="$1" 'NR==1 || $1!=n' "$REGISTRY" >"$tmp"
  chmod 600 "$tmp"; mv "$tmp" "$REGISTRY"
}
reg_del() { with_lock _reg_del "$1"; }

# ----------------------------------------------------------------------------- secrets
secret_save() {  # name password(stdin)
  openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass "file:$MASTER_KEY" \
    -out "$SECRETS/$1.enc"
  chmod 600 "$SECRETS/$1.enc"
}
secret_load() {  # name -> password on stdout
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -pass "file:$MASTER_KEY" \
    -in "$SECRETS/$1.enc"
}

# ----------------------------------------------------------------------------- ssh
SSH_OPTS=(-o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new
          -o "UserKnownHostsFile=$KNOWN_HOSTS" -o ServerAliveInterval=15)

ssh_key() {  # ip port cmd...
  local ip=$1 port=$2; shift 2
  ssh "${SSH_OPTS[@]}" -o BatchMode=yes -i "$SSH_KEY" -p "$port" "root@$ip" "$@"
}
ssh_pw() {  # ip port password cmd...   (password goes through the environment, not argv)
  local ip=$1 port=$2 pw=$3; shift 3
  SSHPASS=$pw sshpass -e ssh "${SSH_OPTS[@]}" -o PubkeyAuthentication=no \
    -o PreferredAuthentications=password,keyboard-interactive -p "$port" "root@$ip" "$@"
}
srv_ssh() {  # name cmd...
  local name=$1; shift
  ssh_key "$(reg_get "$name" $F_IP)" "$(reg_get "$name" $F_PORT)" "$@"
}

install_key() {  # ip port password
  local pub; pub=$(cat "$SSH_KEY.pub")
  ssh_pw "$1" "$2" "$3" "umask 077; mkdir -p /root/.ssh; touch /root/.ssh/authorized_keys;
    grep -qxF '$pub' /root/.ssh/authorized_keys || echo '$pub' >>/root/.ssh/authorized_keys"
}

rekey_with_password() {  # name -> 0 if key login works again
  local name=$1 ip port pw
  ip=$(reg_get "$name" $F_IP); port=$(reg_get "$name" $F_PORT)
  [[ -f $SECRETS/$name.enc ]] || return 1
  pw=$(secret_load "$name") || return 1
  install_key "$ip" "$port" "$pw" >/dev/null 2>&1 || return 1
  ssh_key "$ip" "$port" true >/dev/null 2>&1
}

wait_for_ssh() {  # ip port timeout_seconds
  local deadline=$(( $(now) + $3 ))
  while (( $(now) < deadline )); do
    ssh_key "$1" "$2" true >/dev/null 2>&1 && return 0
    sleep 5
  done
  return 1
}

# ----------------------------------------------------------------------------- firewall
firewall_allow() {  # ip
  command -v ufw >/dev/null && ufw status | grep -q '^Status: active' || {
    warn "ufw is not active on main. Restrict DB ports yourself; allow only $1 to: $FIREWALL_PORTS"
    return 0
  }
  confirm "Allow $1 to reach ports ($FIREWALL_PORTS) on this main server?" || return 0
  local p; for p in $FIREWALL_PORTS; do ufw allow from "$1" to any port "$p" proto tcp >/dev/null; done
  ok "Firewall rules added for $1"; log "ufw allow $1 ports $FIREWALL_PORTS"
}
firewall_remove() {  # ip
  command -v ufw >/dev/null && ufw status | grep -q '^Status: active' || return 0
  local p; for p in $FIREWALL_PORTS; do ufw delete allow from "$1" to any port "$p" proto tcp >/dev/null 2>&1 || true; done
  log "ufw removed $1"
}

# ----------------------------------------------------------------------------- specs
suggest_max() {  # cpus ram_mb -> suggested max teachers
  awk -v c="$1" -v r="$2" -v cpt="$CORES_PER_TEACHER" -v rpt="$RAM_MB_PER_TEACHER" -v res="$RAM_MB_RESERVED" '
    BEGIN { a = int(c / cpt); b = int((r - res) / rpt); m = (a < b ? a : b); print (m < 1 ? 1 : m) }'
}

detect_specs() {  # ip port -> "cpus ram_mb"
  ssh_key "$1" "$2" 'echo "$(nproc) $(awk "/MemTotal/ {print int(\$2/1024)}" /proc/meminfo)"'
}

# ----------------------------------------------------------------------------- clone
choose_template() {  # -> "local" or a template name
  local templates; mapfile -t templates < <(reg_names template)
  echo "Clone from which server?" >&2
  echo "  0) this main server (local)" >&2
  local i; for i in "${!templates[@]}"; do echo "  $((i+1))) ${templates[$i]}" >&2; done
  local pick; pick=$(ask "Choice" 0)
  if [[ $pick == 0 ]]; then printf 'local'
  elif valid_int "$pick" && (( pick >= 1 && pick <= ${#templates[@]} )); then printf '%s' "${templates[$((pick-1))]}"
  else die "Invalid choice."; fi
}

os_version() {  # "local" | name -> VERSION_ID
  local q='. /etc/os-release; echo "$ID $VERSION_ID"'
  if [[ $1 == local ]]; then bash -c "$q"; else srv_ssh "$1" "$q"; fi
}

tpl_run() {  # "local" | template-name  cmd -> run a command on the template
  local tpl=$1; shift
  if [[ $tpl == local ]]; then bash -c "$*"; else srv_ssh "$tpl" "$@"; fi
}

# Copy paths from the template to the new server with rsync. -R keeps full
# paths, so the /-anchored patterns in the exclude file match for any source.
rsync_from_template() {  # template ip port logfile excludes-file source-path...
  local tpl=$1 ip=$2 port=$3 logf=$4 excl=$5; shift 5
  local srcs="$*" rc=0
  local rs_ssh="ssh -p $port -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
  local rs_opts="-aHAXR --numeric-ids --info=progress2 --stats"

  ssh_key "$ip" "$port" 'command -v rsync >/dev/null || (apt-get update -qq && apt-get install -y -qq rsync)'
  if [[ $tpl == local ]]; then
    # shellcheck disable=SC2086
    rsync $rs_opts --exclude-from="$excl" \
      -e "$rs_ssh -i $SSH_KEY -o UserKnownHostsFile=$KNOWN_HOSTS" \
      $srcs "root@$ip:/" 2> >(tee -a "$logf" >&2) | tee -a "$logf" || rc=$?
  else
    # Template pushes straight to the new server. The fleet key never leaves
    # main: it is lent through a temporary ssh-agent (agent forwarding).
    local t_ip t_port; t_ip=$(reg_get "$tpl" $F_IP); t_port=$(reg_get "$tpl" $F_PORT)
    ssh_key "$t_ip" "$t_port" 'command -v rsync >/dev/null || (apt-get update -qq && apt-get install -y -qq rsync)'
    scp "${SSH_OPTS[@]}" -o BatchMode=yes -i "$SSH_KEY" -P "$t_port" \
      "$excl" "root@$t_ip:/root/.tplus-fleet-excludes.txt" >/dev/null
    eval "$(ssh-agent -s)" >/dev/null
    ssh-add -q "$SSH_KEY"
    ssh "${SSH_OPTS[@]}" -A -o BatchMode=yes -p "$t_port" "root@$t_ip" \
      "rsync $rs_opts --exclude-from=/root/.tplus-fleet-excludes.txt -e '$rs_ssh' $srcs root@$ip:/" \
      2> >(tee -a "$logf" >&2) | tee -a "$logf" || rc=$?
    ssh-agent -k >/dev/null || true
  fi
  return "$rc"
}

# ----------------------------------------------------------------------------- methods
# A migration method is a file in $FLEET_ETC/methods/<id>.sh that sets:
#   METHOD_INFO            one line shown in the menu
#   METHOD_NEEDS_TEMPLATE  yes|no  (ask which server to copy from)
#   METHOD_COPIES_SYSTEM   yes|no  (copies /etc: restore root password + reboot after)
#   method_run TEMPLATE IP PORT LOGFILE   does the copy; exit 0 ok, 23/24 partial
# Inside method_run you can use: tpl_run, ssh_key, rsync_from_template, info,
# warn, $EXCLUDES, $APP_DIR, $SSH_KEY. Add a method by dropping in a new file.
write_default_methods() {
  install -d -m 700 "$FLEET_ETC/methods" "$FLEET_ETC/hooks"

  [[ -f $FLEET_ETC/methods/rsync-full.sh ]] || cat >"$FLEET_ETC/methods/rsync-full.sh" <<'EOF'
METHOD_INFO="Full system copy with rsync (RackNerd method + fixes). Slowest (~30 min / 21 GB)."
METHOD_NEEDS_TEMPLATE=yes
METHOD_COPIES_SYSTEM=yes
method_run() { rsync_from_template "$1" "$2" "$3" "$4" "$EXCLUDES" /; }
EOF

  [[ -f $FLEET_ETC/methods/rsync-app.sh ]] || cat >"$FLEET_ETC/methods/rsync-app.sh" <<'EOF'
METHOD_INFO="Install the template's apt packages, then copy only the app user + /usr/local + /opt."
METHOD_NEEDS_TEMPLATE=yes
METHOD_COPIES_SYSTEM=no
APP_SYNC_PATHS="/home/desktop /usr/local /opt"
method_run() {  # template ip port logfile
  local tpl=$1 ip=$2 port=$3 logf=$4 uid gid
  # Same user with the same uid/gid, so copied files keep the right owner.
  read -r uid gid < <(tpl_run "$tpl" 'echo "$(id -u desktop) $(id -g desktop)"')
  ssh_key "$ip" "$port" "getent group desktop >/dev/null || groupadd -g $gid desktop
    id desktop >/dev/null 2>&1 || useradd -m -u $uid -g $gid -s /bin/bash desktop"
  # Packages installed by hand on the template; ones the new server can't find are skipped.
  info "Installing the template's packages (can take several minutes)..."
  tpl_run "$tpl" 'apt-mark showmanual' | ssh_key "$ip" "$port" '
    export DEBIAN_FRONTEND=noninteractive
    cat >/tmp/tplus-pkgs.txt; apt-get update -qq
    xargs -a /tmp/tplus-pkgs.txt apt-get install -y -qq >/dev/null 2>&1 ||
      while read -r p; do apt-get install -y -qq "$p" >/dev/null 2>&1 || echo "skipped package: $p"; done </tmp/tplus-pkgs.txt' \
    | tee -a "$logf"
  # shellcheck disable=SC2086
  rsync_from_template "$tpl" "$ip" "$port" "$logf" "$EXCLUDES" $APP_SYNC_PATHS
}
EOF

  [[ -f $FLEET_ETC/methods/custom.sh.example ]] || cat >"$FLEET_ETC/methods/custom.sh.example" <<'EOF'
# Copy to <name>.sh to enable. Example: copy only the app folder onto a server
# that is already prepared (same packages, user and Node already installed).
METHOD_INFO="Copy only the app folder (server already prepared)."
METHOD_NEEDS_TEMPLATE=yes
METHOD_COPIES_SYSTEM=no
method_run() { rsync_from_template "$1" "$2" "$3" "$4" "$EXCLUDES" "$APP_DIR"; }
EOF

  [[ -f $FLEET_ETC/hooks/post-worker.sh.example ]] || cat >"$FLEET_ETC/hooks/post-worker.sh.example" <<'EOF'
# Copy to post-worker.sh to enable. Runs as root ON THE WORKER after every
# setup or re-run of worker fixes. Example:
# timedatectl set-timezone Asia/Riyadh
EOF
}

choose_method() {  # -> path of the chosen method file
  local files=() f i def=1
  for f in "$FLEET_ETC"/methods/*.sh; do [[ -f $f ]] && files+=("$f"); done
  ((${#files[@]})) || die "No methods in $FLEET_ETC/methods (run init)."
  echo "Migration method:" >&2
  for i in "${!files[@]}"; do
    f=${files[$i]}
    [[ $(basename "$f" .sh) == "${DEFAULT_METHOD:-rsync-full}" ]] && def=$((i+1))
    printf '  %d) %-12s %s\n' $((i+1)) "$(basename "$f" .sh)" "$( (source "$f"; echo "$METHOD_INFO") )" >&2
  done
  local p; p=$(ask "Choice" "$def")
  valid_int "$p" && (( p >= 1 && p <= ${#files[@]} )) || die "Invalid choice."
  printf '%s' "${files[$((p-1))]}"
}

# Settings added after v1 init: fall back to defaults if fleet.conf predates them.
: "${APP_DIR:=/home/desktop/Web-App}"
: "${WORKER_DISABLE_CONTAINERS:=mongodb my-redis}"
: "${DNS_CHECK_HOSTS:=schools.madrasati.sa login.microsoftonline.com teams.microsoft.com}"
: "${HOSTS_PINS=20.203.8.77 schools.madrasati.sa}"

worker_fixups() {  # name ip port — make a cloned server a correct worker (safe to re-run)
  local name=$1 ip=$2 port=$3
  ssh_key "$ip" "$port" "hostnamectl set-hostname tplus-$name 2>/dev/null || true"

  # Databases: a worker uses main's DB, so local copies must not run.
  info "Disabling local DB containers: $WORKER_DISABLE_CONTAINERS"
  ssh_key "$ip" "$port" "command -v docker >/dev/null || exit 0
    for c in $WORKER_DISABLE_CONTAINERS; do
      docker inspect \"\$c\" >/dev/null 2>&1 || continue
      docker update --restart=no \"\$c\" >/dev/null; docker stop \"\$c\" >/dev/null 2>&1 || true
    done"

  # Secrets/state from the template (already excluded on new clones; needed for older ones).
  ssh_key "$ip" "$port" "rm -rf '$APP_DIR'/cookies/* /home/*/.copilot /root/.bash_history /home/*/.bash_history"

  # App config: worker.env, with LOCAL_NETWORKS set to THIS server's IP
  # (a copied value makes every Madrasati/Microsoft request use the wrong source IP).
  if [[ -f $WORKER_ENV ]]; then
    grep -qE '@(localhost|127\.0\.0\.1)[:/]' "$WORKER_ENV" \
      && warn "$WORKER_ENV points MongoDB/Redis to localhost: the worker has no local DB. Use main's IP."
    scp "${SSH_OPTS[@]}" -o BatchMode=yes -i "$SSH_KEY" -P "$port" -q "$WORKER_ENV" "root@$ip:$APP_DIR/.env"
    ssh_key "$ip" "$port" "cd '$APP_DIR' && chown desktop:desktop .env && chmod 600 .env &&
      if grep -q '^LOCAL_NETWORKS=' .env; then sed -i 's|^LOCAL_NETWORKS=.*|LOCAL_NETWORKS=$ip|' .env;
      else echo 'LOCAL_NETWORKS=$ip' >>.env; fi"
    ok "Worker .env installed (LOCAL_NETWORKS=$ip)."
  else
    warn "No $WORKER_ENV: the worker has no app .env. Create it on main and re-run this step."
  fi

  # Pinned names (replaces any older line for the same name).
  local pin pins pip pname
  IFS=';' read -r -a pins <<<"$HOSTS_PINS"
  for pin in "${pins[@]}"; do
    read -r pip pname <<<"$pin"
    [[ -n ${pname:-} ]] || continue
    ssh_key "$ip" "$port" "sed -i '/[[:space:]]${pname//./\\.}\$/d' /etc/hosts && echo '$pip $pname' >>/etc/hosts"
    ok "/etc/hosts: $pip $pname"
  done

  # DNS: the app fails with ENOTFOUND if these do not resolve.
  local h bad=()
  for h in $DNS_CHECK_HOSTS; do
    ssh_key "$ip" "$port" "getent hosts $h >/dev/null" || bad+=("$h")
  done
  if ((${#bad[@]})); then
    warn "DNS on $ip cannot resolve: ${bad[*]}"
    warn "Check: resolvectl status   (provider DNS may be missing or blocked)"
  else
    ok "DNS resolves: $DNS_CHECK_HOSTS"
  fi

  # Your own extra steps, if any (see hooks/post-worker.sh.example).
  if [[ -f $FLEET_ETC/hooks/post-worker.sh ]]; then
    info "Running hooks/post-worker.sh on $ip"
    ssh_key "$ip" "$port" 'bash -s' <"$FLEET_ETC/hooks/post-worker.sh" || warn "post-worker hook failed on $ip"
  fi

  log "fixups done $name"
  worker_install_services "$name" "$ip" "$port"
}

# Virtual screen (Xvfb :99 + xfwm4) and the app as systemd services, so the app
# runs without a remote-desktop session, survives closing SSH and starts on boot.
worker_install_services() {  # name ip port
  local name=$1 ip=$2 port=$3 node
  node=$(ssh_key "$ip" "$port" "ls -d /home/desktop/.nvm/versions/node/*/bin/node 2>/dev/null | sort -V | tail -1")
  [[ -n $node ]] || { warn "Node (nvm) not found for user desktop on $ip; services not installed."; return 0; }

  info "Installing display + app services on $ip (node: $node)"
  ssh_key "$ip" "$port" "command -v Xvfb >/dev/null && command -v xdotool >/dev/null ||
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
    cat >/etc/systemd/system/tplus-app.service <<'EOF'
[Unit]
Description=TPlus Auto Prepare
After=network-online.target docker.service tplus-display.service
Requires=tplus-display.service

[Service]
User=desktop
WorkingDirectory=$APP_DIR
Environment=DISPLAY=:99
# Same as the app's own pm2:start script
Environment=NODE_ENV=production
# The app binds requests to the IPv4 in LOCAL_NETWORKS; on servers with IPv6,
# IPv6 answers first and the bind fails with EINVAL.
Environment=NODE_OPTIONS=--dns-result-order=ipv4first
ExecStart=$node dist/src/main.js
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now tplus-display >/dev/null 2>&1"
  ok "Display service running on $ip."

  # Without worker mode, a running worker app repeats main's jobs for the same teachers.
  warn "Starting the app here means it also runs jobs for the same teachers as main."
  if confirm "Start the app on $name now and on every boot?"; then
    ssh_key "$ip" "$port" "systemctl enable --now tplus-app >/dev/null 2>&1; sleep 10; systemctl is-active tplus-app" \
      && ok "App running on $name (log: journalctl -u tplus-app -f)" \
      || warn "App did not stay up on $name. Check: journalctl -u tplus-app -n 50"
  else
    ssh_key "$ip" "$port" "systemctl disable --now tplus-app >/dev/null 2>&1 || true"
    info "App installed but not started. Start later: systemctl enable --now tplus-app"
  fi
  log "services installed $name node=$node"
}

cmd_add_worker() { add_server worker; }
cmd_add_template() { add_server template; }
cmd_add_existing() { add_server existing; }

cmd_fix_worker() {
  local name; name=$(pick_server)
  [[ $(reg_get "$name" $F_ROLE) == worker ]] || die "$name is not a worker."
  worker_fixups "$name" "$(reg_get "$name" $F_IP)" "$(reg_get "$name" $F_PORT)"
}

add_server() {  # role: worker (clone onto it) | template (register) | existing (already cloned worker)
  local role=$1 name ip port pw hours tpl cpus ram max fresh
  echo
  case $role in
    worker)   info "Add a NEW worker: a fresh VPS with the same Ubuntu version as the template." ;;
    template) info "Register an existing, fully built server as a clone template." ;;
    existing) info "Register a worker that was ALREADY cloned (no copy; only fixes and registration)." ;;
  esac
  name=$(ask "Name (a-z 0-9 -)" ""); valid_name "$name" || die "Bad name."
  reg_exists "$name" && die "Name already used."
  ip=$(ask "IP address" ""); valid_ip "$ip" || die "Bad IP."
  awk -F'\t' -v i="$ip" 'NR>1 && $2==i {f=1} END {exit !f}' "$REGISTRY" && die "IP already registered."
  port=$(ask "SSH port" 22); valid_int "$port" || die "Bad port."
  pw=$(ask_secret "Root password of $ip")

  info "Checking password login..."
  ssh_pw "$ip" "$port" "$pw" true || die "Cannot log in as root@$ip with that password."
  info "Installing fleet SSH key..."
  install_key "$ip" "$port" "$pw" && ssh_key "$ip" "$port" true || die "SSH key login failed."
  printf '%s' "$pw" | secret_save "$name"
  ok "Key login works; password stored encrypted."

  read -r cpus ram < <(detect_specs "$ip" "$port")
  max=$(ask "Max teachers ($cpus vCPU, $ram MB RAM; suggested)" "$(suggest_max "$cpus" "$ram")")
  valid_int "$max" || die "Bad number."

  if [[ $role == template ]]; then
    reg_add "$name"$'\t'"$ip"$'\t'"$port"$'\ttemplate\tonline\t'"$max"$'\t'"$cpus"$'\t'"$ram"$'\t0\t0\t?\t'"$(now)"$'\t0\t'"$(now)"$'\t0'
    log "registered template $name $ip"; ok "Template $name registered."
    return
  fi

  hours=$(ask "Paid hours bought" "$DEFAULT_PAID_HOURS"); valid_int "$hours" || die "Bad number."

  if [[ $role == existing ]]; then
    reg_add "$name"$'\t'"$ip"$'\t'"$port"$'\tworker\tonline\t'"$max"$'\t'"$cpus"$'\t'"$ram"$'\t0\t0\t?\t'"$(now)"$'\t'"$(( $(now) + hours*3600 ))"$'\t'"$(now)"$'\t0'
    log "registered existing worker $name $ip"
    worker_fixups "$name" "$ip" "$port"
    firewall_allow "$ip"
    health_check "$name" || true
    db_sync || true
    ok "Worker $name registered."
    return
  fi

  write_default_methods
  grep -q puppeteer "$EXCLUDES" \
    || warn "$EXCLUDES predates the Chrome fix: it skips ~/.cache/puppeteer (Chrome). Delete it and run init."
  local mfile mid; mfile=$(choose_method); mid=$(basename "$mfile" .sh)
  unset -f method_run; METHOD_NEEDS_TEMPLATE=yes METHOD_COPIES_SYSTEM=no
  # shellcheck source=/dev/null
  source "$mfile"
  declare -F method_run >/dev/null || die "$mfile does not define method_run."

  tpl=-
  if [[ $METHOD_NEEDS_TEMPLATE == yes ]]; then
    tpl=$(choose_template)
    local v_tpl v_new
    v_tpl=$(os_version "$tpl"); v_new=$(ssh_key "$ip" "$port" '. /etc/os-release; echo "$ID $VERSION_ID"')
    [[ $v_tpl == "$v_new" ]] || die "OS mismatch: template '$v_tpl' vs new '$v_new'. Reinstall the VPS with $v_tpl."
    ok "Same OS on both: $v_new"
  fi

  fresh=$(ssh_key "$ip" "$port" '[ -d /home/desktop ] && echo used || echo fresh')
  [[ $fresh == fresh ]] || { warn "$ip already has /home/desktop: it may not be fresh."; confirm "Overwrite it anyway?" || die "Aborted."; }

  echo
  echo "  Method : $mid"
  echo "  Copy   : $tpl  ->  $name ($ip)"
  echo "  Excludes: $EXCLUDES (DB, secrets and junk are skipped)"
  [[ $METHOD_COPIES_SYSTEM == yes ]] && echo "  The new server will be REBOOTED at the end."
  confirm "Start?" || die "Aborted."

  reg_add "$name"$'\t'"$ip"$'\t'"$port"$'\tworker\tcloning\t'"$max"$'\t'"$cpus"$'\t'"$ram"$'\t0\t0\t?\t'"$(now)"$'\t'"$(( $(now) + hours*3600 ))"$'\t'"$(now)"$'\t0'
  log "migrate start method=$mid $tpl -> $name $ip"

  local logf="$FLEET_LOG/migrate-$name-$(date +%Y%m%d-%H%M%S).log" rc=0 started; started=$(now)
  method_run "$tpl" "$ip" "$port" "$logf" || rc=$?
  case $rc in
    0)     ok "Copy finished in $(( ($(now) - started) / 60 )) min." ;;
    23|24) warn "Copy finished with code $rc (some files skipped/vanished). See $logf" ;;
    *)     reg_set "$name" $F_STATUS failed; die "Method $mid failed (code $rc). See $logf" ;;
  esac

  if [[ $METHOD_COPIES_SYSTEM == yes ]]; then
    # /etc/shadow came from the template: give the new VPS its own root password back.
    info "Restoring the new server's root password..."
    printf 'root:%s\n' "$pw" | ssh_key "$ip" "$port" chpasswd
  fi
  worker_fixups "$name" "$ip" "$port"

  if [[ $METHOD_COPIES_SYSTEM == yes ]]; then
    info "Rebooting $ip..."
    ssh_key "$ip" "$port" 'systemctl reboot' >/dev/null 2>&1 || true
    sleep 15
  fi
  if wait_for_ssh "$ip" "$port" 300 || rekey_with_password "$name"; then
    reg_set "$name" $F_STATUS online
    ok "$name is online."
  else
    reg_set "$name" $F_STATUS unreachable
    warn "$name did not come back within 5 min. Check the provider console."
  fi
  log "migrate done $name method=$mid rc=$rc"
  firewall_allow "$ip"
  health_check "$name" || true
  db_sync || true
}

# ----------------------------------------------------------------------------- health
# Prints key=value lines from the remote server. Chrome sessions = browser
# processes without --type= (renderers/GPU helpers have --type=).
REMOTE_PROBE='
read -r _ u n s i w q sq st _ < /proc/stat; sleep 1
read -r _ u2 n2 s2 i2 w2 q2 sq2 st2 _ < /proc/stat
tot=$(( (u2+n2+s2+i2+w2+q2+sq2+st2) - (u+n+s+i+w+q+sq+st) ))
echo "steal=$(( tot > 0 ? 100 * (st2 - st) / tot : 0 ))"
echo "cpus=$(nproc)"
echo "ram_mb=$(awk "/MemTotal/ {print int(\$2/1024)}" /proc/meminfo)"
echo "sessions=$(ps -eo args= | grep -E "/chrome( |$)" | grep -vc -- "--type=" || true)"
pgrep -f "node .*dist/src/main.js" >/dev/null && echo app_up=yes || echo app_up=no
'

health_check() {  # name -> 0 if reachable
  local name=$1 ip port out status fails paid role
  ip=$(reg_get "$name" $F_IP); port=$(reg_get "$name" $F_PORT)
  status=$(reg_get "$name" $F_STATUS); fails=$(reg_get "$name" $F_FAILS)
  paid=$(reg_get "$name" $F_PAID); role=$(reg_get "$name" $F_ROLE)
  [[ $status == cloning ]] && return 0

  if ! out=$(ssh_key "$ip" "$port" "bash -s" <<<"$REMOTE_PROBE" 2>/dev/null); then
    # Key may have been wiped (e.g. VPS re-installed): try the stored password once.
    if rekey_with_password "$name" && out=$(ssh_key "$ip" "$port" "bash -s" <<<"$REMOTE_PROBE" 2>/dev/null); then
      log "$name: key re-installed with stored password"
    else
      fails=$(( fails + 1 ))
      if (( fails >= FAILS_BEFORE_DOWN )) && [[ $status != unreachable ]]; then
        reg_set "$name" $F_FAILS "$fails" $F_STATUS unreachable
        log "$name: UNREACHABLE after $fails checks (suspended or down?)"
      else
        reg_set "$name" $F_FAILS "$fails"
      fi
      return 1
    fi
  fi

  local steal cpus ram sessions app
  steal=$(sed -n 's/^steal=//p' <<<"$out");   cpus=$(sed -n 's/^cpus=//p' <<<"$out")
  ram=$(sed -n 's/^ram_mb=//p' <<<"$out");    sessions=$(sed -n 's/^sessions=//p' <<<"$out")
  app=$(sed -n 's/^app_up=//p' <<<"$out")

  # Back from unreachable -> online; keep draining/disabled as the admin set them.
  [[ $status == unreachable || $status == failed ]] && { status=online; log "$name: reachable again"; }
  if [[ $role == worker && $paid -gt 0 && $(now) -gt $paid ]]; then
    [[ $status != expired ]] && log "$name: paid time is over"
    status=expired
  elif [[ $status == expired ]]; then
    status=online
  fi
  reg_set "$name" $F_STATUS "$status" $F_CPUS "${cpus:-0}" $F_RAM "${ram:-0}" \
    $F_SESS "${sessions:-0}" $F_STEAL "${steal:-0}" $F_APP "${app:-?}" \
    $F_SEEN "$(now)" $F_FAILS 0
  return 0
}

cmd_health_once() {
  local n; for n in $(reg_names); do health_check "$n" || true; done
  db_sync || true
}

cmd_health_loop() {
  log "health-loop started (every ${HEALTH_INTERVAL}s)"
  while true; do
    cmd_health_once
    sleep "$HEALTH_INTERVAL"
  done
}

# ----------------------------------------------------------------------------- mongo sync
db_sync() {
  [[ ${MONGO_SYNC:-0} == 1 && -n ${MONGO_URI:-} ]] || return 0
  local js
  # Registry values are validated (names, IPs, numbers), so they are safe to inline.
  js=$(awk -F'\t' 'NR>1 {
      printf "db.fleet_servers.updateOne({name:\"%s\"},{$set:{ip:\"%s\",port:%d,role:\"%s\",status:\"%s\",maxTeachers:%d,cpus:%d,ramMb:%d,activeSessions:%d,stealPct:%d,appUp:\"%s\",createdAt:new Date(%d000),paidUntil:new Date(%d000),lastSeen:new Date(%d000),updatedAt:new Date()}},{upsert:true});\n",
        $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14
    }' "$REGISTRY")
  # Drop records of servers removed from the registry.
  js+=$'\n'"db.fleet_servers.deleteMany({name:{\$nin:[$(reg_names | awk '{printf "%s\"%s\"", (NR>1?",":""), $0}')]}});"
  # shellcheck disable=SC2086
  $MONGO_CMD --quiet "$MONGO_URI" <<<"$js" >/dev/null 2>>"$FLEET_LOG/fleet.log" \
    || { log "mongo sync failed"; return 1; }
}

# ----------------------------------------------------------------------------- list
cmd_list() {
  echo
  printf '%-14s %-15s %-9s %-12s %4s %4s %6s %5s %5s %4s %-9s %s\n' \
    NAME IP ROLE STATUS MAX CPU RAM_GB SESS STEAL APP PAID_LEFT LAST_SEEN
  local t; t=$(now)
  awk -F'\t' -v t="$t" 'NR>1 {
    left = ($13 > 0 ? $13 - t : -1)
    pl = (left < 0 && $13 > 0) ? "OVER" : (left < 0 ? "-" : sprintf("%dh%02dm", left/3600, (left%3600)/60))
    seen = t - $14
    printf "%-14s %-15s %-9s %-12s %4s %4s %6.1f %5s %4s%% %4s %-9s %ss ago\n",
      $1, $2, $4, $5, $6, $7, $8/1024, $9 "/" $6, $10, $11, pl, seen
  }' "$REGISTRY"
  local warn_s=$(( PAID_WARN_MIN * 60 ))
  awk -F'\t' -v t="$t" -v w="$warn_s" 'NR>1 && $4=="worker" && $13>0 && $13-t>0 && $13-t<w {
    printf "\n  ! %s: less than %d min of paid time left\n", $1, w/60 }' "$REGISTRY"
  echo
}

# ----------------------------------------------------------------------------- edit / remove
pick_server() {  # -> name
  local names; mapfile -t names < <(reg_names)
  ((${#names[@]})) || die "No servers registered."
  local i; for i in "${!names[@]}"; do echo "  $((i+1))) ${names[$i]}" >&2; done
  local p; p=$(ask "Server" "")
  valid_int "$p" && (( p >= 1 && p <= ${#names[@]} )) || die "Invalid choice."
  printf '%s' "${names[$((p-1))]}"
}

cmd_edit() {
  local name; name=$(pick_server)
  echo "  1) Set max teachers (now $(reg_get "$name" $F_MAX))"
  echo "  2) Add paid hours"
  echo "  3) Set status: online / draining / disabled"
  echo "  4) Re-detect specs (after an upgrade at the provider)"
  echo "  5) Change stored root password"
  local c v; c=$(ask "Choice" "")
  case $c in
    1) v=$(ask "Max teachers" ""); valid_int "$v" || die "Bad number."; reg_set "$name" $F_MAX "$v" ;;
    2) v=$(ask "Hours to add" 1); valid_int "$v" || die "Bad number."
       local base; base=$(reg_get "$name" $F_PAID); (( base < $(now) )) && base=$(now)
       reg_set "$name" $F_PAID $(( base + v*3600 )) ;;
    3) v=$(ask "Status" online); [[ $v =~ ^(online|draining|disabled)$ ]] || die "Bad status."
       reg_set "$name" $F_STATUS "$v" ;;
    4) local cpus ram; read -r cpus ram < <(detect_specs "$(reg_get "$name" $F_IP)" "$(reg_get "$name" $F_PORT)")
       v=$(ask "Max teachers ($cpus vCPU, $ram MB; suggested)" "$(suggest_max "$cpus" "$ram")")
       valid_int "$v" || die "Bad number."
       reg_set "$name" $F_CPUS "$cpus" $F_RAM "$ram" $F_MAX "$v" ;;
    5) ask_secret "New root password" | secret_save "$name" ;;
    *) die "Invalid choice." ;;
  esac
  log "edit $name option $c"; ok "Saved."
  db_sync || true
}

cmd_remove() {
  local name ip; name=$(pick_server); ip=$(reg_get "$name" $F_IP)
  warn "This removes $name ($ip) from the fleet. It does NOT delete the VPS at the provider."
  confirm "Remove $name?" || return 0
  firewall_remove "$ip"
  ssh-keygen -q -R "$ip" -f "$KNOWN_HOSTS" >/dev/null 2>&1 || true
  rm -f "$SECRETS/$name.enc"
  reg_del "$name"
  log "removed $name $ip"; ok "Removed. Delete the VPS at the provider to stop billing."
  db_sync || true
}

# ----------------------------------------------------------------------------- service
cmd_install_service() {
  local bin=/usr/local/sbin/tplus-fleet
  install -m 700 "$(readlink -f "$0")" "$bin"
  cat >/etc/systemd/system/tplus-fleet-health.service <<EOF
[Unit]
Description=tplus-fleet health checks
After=network-online.target docker.service
Wants=network-online.target

[Service]
ExecStart=$bin health-loop
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now tplus-fleet-health.service
  ok "Health service running; it starts again after a reboot of main."
  info "Status: systemctl status tplus-fleet-health   Log: $FLEET_LOG/fleet.log"
}

# ----------------------------------------------------------------------------- menu
menu() {
  while true; do
    cmd_list
    echo "  1) Add NEW worker (clone onto a fresh VPS)"
    echo "  2) Register an ALREADY cloned worker (no copy)"
    echo "  3) Register a template server"
    echo "  4) Re-run worker fixes (DB off, .env, LOCAL_NETWORKS, DNS, services)"
    echo "  5) Health check now"
    echo "  6) Edit a server (max teachers, paid hours, status, specs)"
    echo "  7) Remove a server"
    echo "  8) Install health service (systemd)"
    echo "  9) Show last log lines"
    echo "  q) Quit"
    local c; c=$(ask "Choice" "")
    # Each action runs in a subshell so a 'die' returns to the menu.
    case $c in
      1) ( cmd_add_worker ) || true ;;
      2) ( cmd_add_existing ) || true ;;
      3) ( cmd_add_template ) || true ;;
      4) ( cmd_fix_worker ) || true ;;
      5) ( cmd_health_once ) || true ;;
      6) ( cmd_edit ) || true ;;
      7) ( cmd_remove ) || true ;;
      8) ( cmd_install_service ) || true ;;
      9) tail -n 30 "$FLEET_LOG/fleet.log" 2>/dev/null || true ;;
      q|Q) exit 0 ;;
      *) warn "Unknown choice." ;;
    esac
  done
}

main() {
  case ${1:-menu} in
    init) cmd_init ;;
    menu|health-once|health-loop)
      require_root; require_main; require_tools
      case ${1:-menu} in
        menu) menu ;;
        health-once) cmd_health_once; cmd_list ;;
        health-loop) cmd_health_loop ;;
      esac ;;
    *) die "Usage: $0 [init|menu|health-once|health-loop]" ;;
  esac
}
main "$@"
