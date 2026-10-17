#!/usr/bin/env bash
# Turn a fresh Debian 13 LXC into a remote Claude Code box: an unprivileged
# user, Claude Code, herdr, a tmux session that survives disconnects and
# reboots, and a firewall that keeps the agent off your LAN.
#
# RUNS INSIDE THE CONTAINER, as root. ct/claude.sh (the wizard) runs it for
# you; it also works on its own on any Debian 13 CT, from the CT's console.
# Nothing here touches the Proxmox host. Safe to re-run: every step checks
# before it acts, and re-running is how herdr gets updated.
#
#   --github-keys USER   authorize github.com/USER.keys for SSH
#   --ssh-key "KEY"      authorize one public key (repeatable)
#   --user NAME          the account Claude Code runs as         [claude]
#   --no-herdr           skip herdr
#   --no-lockdown        skip the in-container firewall (see README)
#
# Root's own authorized_keys (what the community-scripts wizard's SSH key
# prompt fills) are copied over too. With no keys at all it still finishes,
# and warns: re-run with --github-keys to add them, from the CT console.
#
# Exit: 0 on success, 1 on any failure.
set -euo pipefail

die() { printf '\033[0;31m✖ %s\033[0m\n' "$1" >&2; exit 1; }
ok() { printf '\033[0;32m✔ %s\033[0m\n' "$1"; }
warn() { printf '\033[1;33m⚠ %s\033[0m\n' "$1"; }

USER_="claude" HERDR=1 LOCKDOWN=1 GITHUB_USER=""
KEYS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --github-keys) GITHUB_USER="${2:-}"; shift ;;
    --ssh-key) KEYS+=("${2:-}"); shift ;;
    --user) USER_="${2:-}"; shift ;;
    --no-herdr) HERDR=0 ;;
    --no-lockdown) LOCKDOWN=0 ;;
    # Piped through `curl | bash`, $0 is bash itself, not this file.
    -h|--help) [ -f "$0" ] && sed -n '2,/^[^#]/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

[ "$(id -u)" -eq 0 ] || die "run as root inside the container"
[ -n "$USER_" ] || die "--user needs a name"
export DEBIAN_FRONTEND=noninteractive

# ── Packages ────────────────────────────────────────────────────────────────
# What an agent reaches for: git/gh, ripgrep, python3, shellcheck, a compiler.
# nftables is for the lockdown below. No Docker — see README for why.
apt-get update -q
apt-get install -y -q --no-install-recommends \
  ca-certificates curl git gh tmux openssh-server locales less nano jq \
  ripgrep fd-find build-essential python3 python3-yaml shellcheck \
  nftables unattended-upgrades
ok "packages"

# tmux renders box-drawing and Claude Code's spinner wrong under a C locale.
sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
locale-gen >/dev/null
update-locale LANG=en_US.UTF-8
ok "locale en_US.UTF-8"

# Security patches without anyone logging in. The Debian default config only
# takes the -security pocket, which is what we want for an unattended box.
echo 'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";' >/etc/apt/apt.conf.d/20auto-upgrades
ok "unattended-upgrades"

# ── User + SSH keys ─────────────────────────────────────────────────────────
# No sudo, on purpose. Claude Code runs as this account, so this account's
# reach is the agent's reach: it can wreck its own home directory and nothing
# else. Root is the CT console in the Proxmox UI when you need it.
if ! id "$USER_" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$USER_"
fi
home="$(getent passwd "$USER_" | cut -d: -f6)"
install -d -m 0700 -o "$USER_" -g "$USER_" "$home/.ssh" "$home/work"
auth="$home/.ssh/authorized_keys"
touch "$auth"
{
  [ -s /root/.ssh/authorized_keys ] && cat /root/.ssh/authorized_keys
  [ -n "$GITHUB_USER" ] && curl -fsSL "https://github.com/${GITHUB_USER}.keys"
  for k in "${KEYS[@]}"; do echo "$k"; done
  cat "$auth"
} | grep -E '^(ssh-|ecdsa-|sk-)' | sort -u >"$auth.new" || true
mv "$auth.new" "$auth"
chown "$USER_:$USER_" "$auth"
chmod 0600 "$auth"
if [ -s "$auth" ]; then
  ok "user $USER_ (no sudo), $(wc -l <"$auth") SSH key(s)"
else
  warn "user $USER_ has NO SSH keys — re-run with --github-keys USER to add them"
fi

# Keys only, and no root over SSH — the console covers root.
cat >/etc/ssh/sshd_config.d/10-claude-lxc.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
systemctl enable -q ssh
systemctl reload ssh 2>/dev/null || systemctl restart ssh
ok "sshd: keys only, no root"

as_user() { runuser -l "$USER_" -c "$1"; }

# ── Claude Code ─────────────────────────────────────────────────────────────
# The native installer, into ~/.local/bin, owned by the user — so its built-in
# auto-update works without root. No Node needed.
if ! as_user 'test -x ~/.local/bin/claude'; then
  as_user 'curl -fsSL https://claude.ai/install.sh | bash'
fi
if ! grep -qs 'local/bin' "$home/.profile"; then
  # shellcheck disable=SC2016 # expanded at login, not now
  echo 'PATH="$HOME/.local/bin:$PATH"' >>"$home/.profile"
fi
ok "claude code ($(as_user 'claude --version' 2>/dev/null || echo 'installed'))"

# ── herdr ───────────────────────────────────────────────────────────────────
# The upstream installer, which fetches the latest release binary. Run as root
# so it lands somewhere on every user's PATH; running it again is the update.
if [ "$HERDR" -eq 1 ]; then
  curl -fsSL https://herdr.dev/install.sh | sh
  # Wherever the installer chose, the claude user must be able to run it.
  bin="$(command -v herdr || true)"
  [ -n "$bin" ] || bin="$(ls /root/.local/bin/herdr /root/bin/herdr 2>/dev/null | head -n1 || true)"
  [ -n "$bin" ] || die "herdr installer finished but no herdr binary was found"
  case "$bin" in
    /usr/*) ;;
    *) install -m 0755 "$bin" /usr/local/bin/herdr; bin=/usr/local/bin/herdr ;;
  esac
  ok "herdr ($("$bin" --version 2>/dev/null || echo "$bin"))"
fi

# ── tmux ────────────────────────────────────────────────────────────────────
# extended-keys lets Shift+Enter reach Claude Code as a newline instead of a
# submit; the large history is for scrolling back through a long agent turn.
if [ ! -f "$home/.tmux.conf" ]; then
  cat >"$home/.tmux.conf" <<'EOF'
set -g mouse on
set -g history-limit 100000
set -g default-terminal "tmux-256color"
set -s extended-keys on
set -as terminal-features 'xterm*:extkeys'
set -s escape-time 10
EOF
  chown "$USER_:$USER_" "$home/.tmux.conf"
fi

# A user-level unit, kept alive by linger, so the `main` session exists after a
# reboot with nobody logged in and outlives every SSH disconnect. It starts an
# empty shell rather than `claude` itself: the first run needs an interactive
# browser login, and a unit that restart-loops on that is worse than nothing.
unit_dir="$home/.config/systemd/user"
install -d -o "$USER_" -g "$USER_" "$home/.config" "$unit_dir"
cat >"$unit_dir/claude-tmux.service" <<'EOF'
[Unit]
Description=Persistent tmux session for Claude Code

[Service]
Type=forking
WorkingDirectory=%h/work
ExecStart=/usr/bin/tmux new-session -d -s main
ExecStop=/usr/bin/tmux kill-session -t main
Restart=on-failure

[Install]
WantedBy=default.target
EOF
chown -R "$USER_:$USER_" "$home/.config"
loginctl enable-linger "$USER_"
uid="$(id -u "$USER_")"
for _ in $(seq 1 10); do
  [ -S "/run/user/$uid/bus" ] && break
  sleep 1
done
as_user "XDG_RUNTIME_DIR=/run/user/$uid systemctl --user daemon-reload && \
  XDG_RUNTIME_DIR=/run/user/$uid systemctl --user enable --now claude-tmux.service"
ok "tmux session 'main' (systemd user unit, lingering)"

# ── Lockdown ────────────────────────────────────────────────────────────────
# Outbound to private ranges is dropped, so the agent reaches the internet
# (Anthropic, GitHub, registries) but not your NAS, router UI or Proxmox. It
# lives in the container's own network namespace, so the host is untouched,
# and root set it, so the sudo-less agent can't lift it. Replies to inbound
# SSH are `established` and pass. DNS goes to whatever resolv.conf names —
# usually the router, which is itself a private address — so those servers
# get a hole above the drop. Last on purpose: if it fails, everything else is
# already in place.
if [ "$LOCKDOWN" -eq 1 ]; then
  dns_rules=""
  for ns in $(awk '$1 == "nameserver" && $2 ~ /^[0-9.]+$/ {print $2}' /etc/resolv.conf); do
    dns_rules+="    ip daddr $ns meta l4proto { tcp, udp } th dport 53 accept"$'\n'
  done
  cat >/etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
# Written by provision.sh --- re-run it to regenerate, or --no-lockdown and
# 'nft flush ruleset' to remove.
flush ruleset

table inet claude_lockdown {
  chain output {
    type filter hook output priority 0; policy accept;
    ct state established,related accept
    oif "lo" accept
${dns_rules}    ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16 } drop
    ip6 daddr fc00::/7 drop
  }
}
EOF
  nft -f /etc/nftables.conf || die "nftables refused the rules — is nf_tables loaded on the host? Re-run with --no-lockdown to skip."
  systemctl enable -q nftables
  ok "lockdown: no outbound to private ranges (DNS excepted)"
fi

ip="$(hostname -I | awk '{print $1}')"
cat <<EOF

Done. From your laptop:
  ssh $USER_@$ip
  cd ~/work && herdr      # or: tmux attach -t main
  claude                  # sign in once with your claude.ai account
EOF
