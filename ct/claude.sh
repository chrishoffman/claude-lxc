#!/usr/bin/env bash
# Proxmox community-scripts wizard for a remote Claude Code + herdr LXC.
#
# Run in the Proxmox node shell:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/chrishoffman/claude-lxc/main/ct/claude.sh)"
#
# The wizard and container creation are the stock community-scripts engine.
# Only the part that runs INSIDE the new container is ours:
# install/claude-install.sh, which runs provision.sh. COMMUNITY_SCRIPTS_URL
# is what points the engine at this repo for that file. A ct/ script fetched
# with curl can't tell the engine where it came from, and without this the
# engine would look for install/claude-install.sh upstream and fail.
export COMMUNITY_SCRIPTS_URL="${COMMUNITY_SCRIPTS_URL:-https://raw.githubusercontent.com/chrishoffman/claude-lxc/main}"

_cs_boot="${COMMUNITY_SCRIPTS_CORE_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../core}/core/build.func"
# shellcheck disable=SC1090
source "$_cs_boot" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/core/build.func")
# Source: https://github.com/chrishoffman/claude-lxc

APP="Claude"
var_tags="${var_tags:-ai;dev}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-8192}"
var_disk="${var_disk:-32}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

# Run this same one-liner from INSIDE the container to update. It re-runs
# provision.sh, which skips what is already in place and updates herdr.
# Claude Code updates itself.
function update_script() {
  header_info
  check_container_storage
  check_container_resources
  if [[ ! -x /usr/local/bin/herdr && ! -d /home/claude ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi
  msg_info "Updating ${APP} LXC"
  $STD bash <(curl -fsSL "${COMMUNITY_SCRIPTS_URL}/provision.sh")
  msg_ok "Updated successfully!"
  exit
}

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} From your laptop:${CL}"
echo -e "${TAB}${BGN}ssh claude@${IP}${CL}"
echo -e "${TAB}${BGN}cd ~/work && herdr${CL}   then run claude in a pane and sign in"
