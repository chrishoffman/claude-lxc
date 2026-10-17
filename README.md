# claude-lxc

One paste in the Proxmox shell gives you a remote
[Claude Code](https://claude.com/claude-code) box: an unprivileged Debian 13
LXC with Claude Code and [herdr](https://herdr.dev).

- **From a terminal:** SSH in and run `herdr`. Agents keep running when you
  disconnect.
- **From your phone:** run `claude remote-control` in a pane, then open it in
  the Claude app. It connects outbound only, so you don't open any ports.
- **Off your LAN:** a firewall inside the container lets the agent reach the
  internet but not your other machines.

## Install

In the Proxmox UI, open your node → **Shell** and run:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/chrishoffman/claude-lxc/main/install.sh)"
```

It asks these questions; press Enter on any of them to take the default:

| Question | Default |
|---|---|
| Storage | `local-zfs` or `local-lvm`, if one exists |
| Container ID | the next ID that's actually free |
| Hostname | `claude` |
| CPU cores | 4 |
| RAM | 8192 MB |
| Disk | 32 GB |
| Bridge | `vmbr0` |
| IP | `dhcp`, or a CIDR such as `192.168.1.50/24` (then it asks for a gateway) |
| GitHub user | none. Give a username and the keys at `github.com/<user>.keys` can SSH in |

Then it shows a summary and asks once more before it changes anything.

On the host, it only downloads the Debian 13 template and runs `pct create`
and `pct start`. Everything else runs **inside** the container, through
`provision.sh`. That script sets up:

- a `claude` user with **no sudo**
- SSH that takes keys only and refuses root logins
- Claude Code, from the native installer, which updates itself
- herdr
- a tmux session called `main` that survives reboots, for when you don't use
  herdr
- unattended security updates
- the [lockdown](#lockdown) firewall

When an ID is taken, the installer tells you why. It might be an existing
guest, a config file, a disk a deleted guest left on **any** storage, or an LVM
volume that no storage points at, such as one on an old host's disk you've
plugged in. The last two are the confusing cases. Proxmox's own "next ID" and
its UI don't show them, but reusing that ID is risky: `pct rescan` would
attach the old disk to the new container, and destroying the container later
could delete that disk.

Unattended: set the answers as environment variables and add `--yes`.

```bash
CT_ID=120 CT_IP=192.168.1.50/24 CT_GW=192.168.1.1 GITHUB_KEYS=octocat \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/chrishoffman/claude-lxc/main/install.sh)" _ --yes
```

The variables are `CT_ID`, `CT_HOSTNAME`, `CT_CORES`, `CT_RAM`, `CT_DISK`,
`CT_STORAGE`, `CT_BRIDGE`, `CT_IP`, `CT_GW` and `GITHUB_KEYS`.

## First login

From your laptop:

```bash
ssh claude@<container-ip>
cd ~/work && herdr        # ctrl+b q detaches; `herdr` reattaches
```

In a herdr pane, run `claude` and sign in with your **claude.ai** account.
Remote Control needs that kind of sign-in, so don't use an API key. After that,
for each session:

```bash
cd ~/work/<repo> && claude remote-control
```

To reach the box away from home, use whatever already gets you onto your LAN,
such as a Tailscale subnet router or a VPN. Don't port-forward SSH.

## GitHub access

1. Create a **fine-grained PAT** that covers only the repos the agent should
   touch, with `Contents: read/write` and `Pull requests: read/write`.
2. In the container, run:

   ```bash
   gh auth login --with-token     # paste the PAT
   gh auth setup-git
   git config --global user.name "…"
   git config --global user.email "…"
   ```

If a push to a repo's default branch deploys something, turn on branch
protection there (PRs required) *before* you give the agent write access.

## Update

Open the container's **Console** and run:

```bash
/root/provision.sh
```

It skips everything that's already set up and updates herdr. Claude Code
updates itself.

## Without the installer

`provision.sh` works on its own on any Debian 13 container. Run it as root in
the container's console:

```bash
curl -fsSL https://raw.githubusercontent.com/chrishoffman/claude-lxc/main/provision.sh \
  | bash -s -- --github-keys <your-github-username>
```

These flags are available:

- `--ssh-key "ssh-ed25519 …"`: authorize this key. You can repeat it.
- `--user NAME`: create a different user name.
- `--no-herdr`: skip herdr.
- `--no-lockdown`: skip the firewall.

## Lockdown

`provision.sh` writes `/etc/nftables.conf` inside the container. It **drops
outbound traffic to private ranges**:

- `10/8`, `172.16/12` and `192.168/16`
- `100.64/10`
- link-local addresses
- IPv6 ULA

DNS to the nameservers in `/etc/resolv.conf` is still allowed. The agent can
reach Anthropic, GitHub and package registries, but not your NAS, your
router's admin page or Proxmox. Inbound SSH still works, because its replies
belong to an established connection.

The rules live in the container's own network namespace, so the host is left
alone. Root sets them and the agent has no sudo, so the agent can't remove
them.

- **To allow one LAN service:** as root, add
  `ip daddr X tcp dport Y accept` above the drop line, then run
  `nft -f /etc/nftables.conf`.
- **To turn it off:** run `nft flush ruleset && systemctl disable nftables`.
- **If nft refuses the rules:** the host's `nf_tables` module isn't loaded,
  and an unprivileged container can't load it. Run `modprobe nf_tables` on the
  host, or provision with `--no-lockdown`.

## Deliberately missing

- **sudo:** the agent can damage `~claude` and nothing else. For root, use the
  container's console in the Proxmox UI.
- **Docker:** it needs extra container features, and access to the Docker
  socket is effectively root.

## Layout

| File | Runs | Does |
|---|---|---|
| `install.sh` | Proxmox host | asks the questions, creates the container, and pushes `provision.sh` into it |
| `provision.sh` | in the CT | everything else; it also works on its own |
