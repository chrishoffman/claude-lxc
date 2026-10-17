#!/usr/bin/env bash
# Create a Claude Code + herdr LXC on Proxmox, then provision it.
#
# Run in the Proxmox node shell (the web UI's node → Shell is fine):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/chrishoffman/claude-lxc/main/install.sh)"
#
# It asks a handful of questions, every one with a default — press Enter to
# take it. On the host it only runs pveam/pct to create one unprivileged
# container; everything else is provision.sh, run INSIDE that container.
#
# Unattended: answer with environment variables and pass --yes, e.g.
#   CT_ID=120 CT_IP=192.168.1.50/24 GITHUB_KEYS=octocat bash install.sh --yes
# Variables: CT_ID CT_HOSTNAME CT_CORES CT_RAM CT_DISK CT_STORAGE CT_BRIDGE
#            CT_IP (dhcp or CIDR) CT_GW GITHUB_KEYS
set -euo pipefail

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/chrishoffman/claude-lxc/main}"

B=$'\033[1m' G=$'\033[0;32m' Y=$'\033[1;33m' R=$'\033[0;31m' D=$'\033[2m' N=$'\033[0m'
die() { printf '%s✖ %s%s\n' "$R" "$1" "$N" >&2; exit 1; }
ok() { printf '%s✔%s %s\n' "$G" "$N" "$1"; }
step() { printf '%s…%s %s\n' "$Y" "$N" "$1"; }

YES=0
case "${1:-}" in
  -y|--yes) YES=1 ;;
  -h|--help) sed -n '2,/^[^#]/p' "$0" 2>/dev/null | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) die "unknown argument: $1" ;;
esac

# ask VAR "Question" default — sets VAR. Reads the terminal directly, because
# under `bash -c "$(curl …)"` there is no script on stdin to confuse it with,
# but under `curl … | bash` there is.
ask() {
  local var=$1 q=$2 def=$3 ans=""
  if [ "$YES" -eq 0 ]; then
    read -r -p "  ${q} ${D}[${def}]${N}: " ans </dev/tty || true
  fi
  printf -v "$var" '%s' "${ans:-$def}"
}

[ "$(id -u)" -eq 0 ] || die "run as root on the Proxmox host"
command -v pct >/dev/null && command -v pvesh >/dev/null || die "no pct/pvesh — run this on the Proxmox host"

# ── Why an ID is "taken" — said plainly, so a stale disk is not a mystery ──
id_owner() {
  local id=$1
  if pvesh get /cluster/resources --type vm --output-format json 2>/dev/null |
    grep -qE "\"vmid\":[[:space:]]*${id}[,}]"; then
    echo "guest $id exists in the cluster"; return 0
  fi
  local f
  for f in /etc/pve/nodes/*/lxc/"$id".conf /etc/pve/nodes/*/qemu-server/"$id".conf; do
    [ -e "$f" ] && { echo "$f exists"; return 0; }
  done
  local vol
  vol="$(pvesm list "$CT_STORAGE" 2>/dev/null | awk -v id="$id" '$NF == id {print $1; exit}')"
  if [ -n "$vol" ]; then
    echo "an orphaned disk of $id is still on $CT_STORAGE ($vol)"; return 0
  fi
  return 1
}

# ── Defaults ────────────────────────────────────────────────────────────────
# Storage: the first one that holds container root disks, preferring the
# usual names. pvesm prints a header line; skip it.
storages="$(pvesm status --content rootdir 2>/dev/null | awk 'NR > 1 && $3 == "active" {print $1}')"
[ -n "$storages" ] || die "no active storage accepts container disks (content: rootdir)"
def_storage="$(printf '%s\n' "$storages" | grep -xE 'local-zfs|local-lvm' | head -n1 || true)"
def_storage="${def_storage:-$(printf '%s\n' "$storages" | head -n1)}"
def_gw="$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}' || true)"

printf '\n%sClaude Code LXC%s — Enter takes the default.\n\n' "$B" "$N"

ask CT_STORAGE "Storage ($(echo "$storages" | paste -sd, -))" "${CT_STORAGE:-$def_storage}"
printf '%s\n' "$storages" | grep -qx "$CT_STORAGE" || die "no such storage: $CT_STORAGE"

# Proxmox's nextid only knows about guests, not about disks a deleted guest
# left behind, so walk up from it until id_owner finds nothing either.
next_free() {
  local id=$1
  while id_owner "$id" >/dev/null; do id=$((id + 1)); done
  echo "$id"
}

def_id="${CT_ID:-$(next_free "$(pvesh get /cluster/nextid)")}"
while true; do
  ask CT_ID "Container ID" "$def_id"
  [[ "$CT_ID" =~ ^[0-9]+$ ]] || { echo "  ${R}not a number${N}"; [ "$YES" -eq 1 ] && exit 1; continue; }
  if why="$(id_owner "$CT_ID")"; then
    echo "  ${R}${CT_ID} is taken: ${why}${N}"
    [ "$YES" -eq 1 ] && exit 1
    def_id="$(next_free "$((CT_ID + 1))")"
    continue
  fi
  break
done

ask CT_HOSTNAME "Hostname" "${CT_HOSTNAME:-claude}"
ask CT_CORES "CPU cores" "${CT_CORES:-4}"
ask CT_RAM "RAM (MB)" "${CT_RAM:-8192}"
ask CT_DISK "Disk (GB)" "${CT_DISK:-32}"
ask CT_BRIDGE "Bridge" "${CT_BRIDGE:-vmbr0}"
ask CT_IP "IP (dhcp, or CIDR like 192.168.1.50/24)" "${CT_IP:-dhcp}"
CT_GW="${CT_GW:-}"
if [ "$CT_IP" != "dhcp" ]; then
  [[ "$CT_IP" == */* ]] || die "a static IP needs a prefix length, e.g. ${CT_IP}/24"
  ask CT_GW "Gateway" "${CT_GW:-$def_gw}"
  [ -n "$CT_GW" ] || die "a static IP needs a gateway"
fi
ask GITHUB_KEYS "GitHub user whose SSH keys may log in (blank: none)" "${GITHUB_KEYS:-}"

cat <<EOF

  ${B}CT ${CT_ID}${N} ${CT_HOSTNAME} · ${CT_CORES} cores · ${CT_RAM} MB · ${CT_DISK} GB on ${CT_STORAGE}
  ${CT_BRIDGE} · ${CT_IP}${CT_GW:+ via $CT_GW} · SSH keys: ${GITHUB_KEYS:-none}
  unprivileged Debian 13, Claude Code, herdr, LAN lockdown

EOF
if [ "$YES" -eq 0 ]; then
  read -r -p "  Create it? [Y/n]: " go </dev/tty || true
  [[ "${go:-y}" =~ ^[Yy] ]] || die "cancelled"
fi

# ── Template ────────────────────────────────────────────────────────────────
# Newest Debian 13 standard, resolved now rather than pinned: the point
# release in its filename changes, and pveam only offers the current one.
step "finding the Debian 13 template"
tmpl_store="$(pvesm status --content vztmpl 2>/dev/null | awk 'NR > 1 && $3 == "active" {print $1; exit}')"
[ -n "$tmpl_store" ] || die "no active storage accepts templates (content: vztmpl)"
pveam update >/dev/null
template="$(pveam available --section system | awk '$2 ~ /^debian-13-standard_/ {print $2}' | sort -V | tail -n1)"
[ -n "$template" ] || die "pveam offers no debian-13-standard template"
if ! pveam list "$tmpl_store" | grep -q "$template"; then
  pveam download "$tmpl_store" "$template" >/dev/null
fi
ok "template $template"

# ── Container ───────────────────────────────────────────────────────────────
net="name=eth0,bridge=${CT_BRIDGE}"
if [ "$CT_IP" = "dhcp" ]; then net+=",ip=dhcp"; else net+=",ip=${CT_IP},gw=${CT_GW}"; fi

# unprivileged: root in the CT is an unprivileged uid on the host.
# nesting=1 is what Debian 13's systemd needs in an unprivileged CT (and what
# Proxmox's own wizard turns on by default); there is no Docker in here.
step "creating CT ${CT_ID}"
pct create "$CT_ID" "${tmpl_store}:vztmpl/${template}" \
  --hostname "$CT_HOSTNAME" \
  --unprivileged 1 \
  --features nesting=1 \
  --cores "$CT_CORES" \
  --memory "$CT_RAM" \
  --swap 1024 \
  --rootfs "${CT_STORAGE}:${CT_DISK}" \
  --net0 "$net" \
  --onboot 1 \
  --tags claude >/dev/null
pct start "$CT_ID"
ok "CT ${CT_ID} created and started"

step "waiting for its network"
for _ in $(seq 1 60); do
  pct exec "$CT_ID" -- getent hosts deb.debian.org >/dev/null 2>&1 && break
  sleep 2
done
pct exec "$CT_ID" -- getent hosts deb.debian.org >/dev/null 2>&1 || die "CT ${CT_ID} has no working DNS after 2 minutes — check its network settings"
ok "network up"

# ── Provision (inside the CT) ───────────────────────────────────────────────
# Fetched on the host and pushed in, so the template doesn't need curl.
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
curl -fsSL "${REPO_RAW}/provision.sh" -o "$tmp" || die "could not download provision.sh"
pct push "$CT_ID" "$tmp" /root/provision.sh --perms 0755
args=()
[ -n "$GITHUB_KEYS" ] && args+=(--github-keys "$GITHUB_KEYS")
step "provisioning inside CT ${CT_ID} (a few minutes)"
pct exec "$CT_ID" -- /root/provision.sh "${args[@]}"
