# claude-lxc

A [Proxmox community-scripts](https://community-scripts.github.io/ProxmoxVE/)
style installer for a remote [Claude Code](https://claude.com/claude-code)
box. It sets up an unprivileged Debian 13 LXC with Claude Code and
[herdr](https://herdr.dev), and makes one paste.

- **From a terminal:** SSH in and run `herdr`. Agents keep running after you
  disconnect.
- **From your phone:** run `claude remote-control` in a pane, then open it in
  the Claude app. It connects outbound only, so no ports need to be open.
- **Off your LAN:** a firewall inside the container lets the agent reach the
  internet but not your other machines.

## Install

In the Proxmox UI, open your node → **Shell** and run:

```bash
GITHUB_KEYS=<your-github-username> \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/chrishoffman/claude-lxc/main/ct/claude.sh)"
```

It's the usual community-scripts wizard, with defaults of 4 cores, 8 GB RAM,
a 32 GB disk, Debian 13 and an unprivileged container. Choose **Default**, or
**Advanced** to set a static IP or hostname. `GITHUB_KEYS` authorizes the
public keys from `github.com/<user>.keys` for SSH. You can leave it off and
paste a key at the wizard's SSH key prompt (Advanced) instead.

The wizard creates the container. Then, inside it, it sets up:

- a `claude` user with **no sudo**
- SSH that accepts keys only and refuses root login
- Claude Code, from the native installer, which keeps itself updated
- herdr
- a tmux session `main` that survives reboots, for when you don't want herdr
- unattended security updates
- the [lockdown](#lockdown) firewall

The only host-side code is the community-scripts engine creating a container.
Everything this repo adds runs inside the container.

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

Open the container's **Console** and run the same one-liner, without
`GITHUB_KEYS`. It re-runs `provision.sh`, which skips anything already set up
and updates herdr. Claude Code updates itself.

## Without the wizard

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
| `ct/claude.sh` | Proxmox host | the community-scripts wizard; points the engine at this repo |
| `install/claude-install.sh` | in the CT | the engine's install hook; runs `provision.sh` |
| `provision.sh` | in the CT | everything else; also usable on its own |
