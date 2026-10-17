#!/usr/bin/env bash
# Runs INSIDE the new container. The community-scripts engine fetches it from
# COMMUNITY_SCRIPTS_URL (set by ct/claude.sh) and passes that variable through,
# along with its helper library in FUNCTIONS_FILE_PATH.
#
# The real work is provision.sh, kept standalone so it also runs on any
# Debian 13 container without the wizard. SSH keys reach it two ways:
#   - the wizard's own SSH key prompt (Advanced), which puts them in root's
#     authorized_keys; provision.sh copies those to the claude user
#   - GITHUB_KEYS=<github-user> in front of the one-liner on the host
# Source: https://github.com/chrishoffman/claude-lxc

# shellcheck disable=SC1091
source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Claude Code, herdr and the claude user"
args=()
[[ -n "${GITHUB_KEYS:-}" ]] && args+=(--github-keys "$GITHUB_KEYS")
$STD bash <(curl -fsSL "${COMMUNITY_SCRIPTS_URL}/provision.sh") "${args[@]}"
msg_ok "Installed Claude Code, herdr and the claude user"

motd_ssh
customize
cleanup_lxc
