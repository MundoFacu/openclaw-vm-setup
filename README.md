# openclaw-vm-setup

Setup script to get [OpenClaw](https://github.com/openclaw) running on a fresh Ubuntu Server VM. Works with any hypervisor — VirtualBox, QEMU/KVM, Proxmox, Hyper-V, whatever. A VM is a VM.

Based on [this Nightly Ventures guide](https://www.nightlyventures.com/p/self-host-moltbot-on-proxmox), with one key difference: **sudo is revoked after installation**. The original guide leaves `NOPASSWD` permanently, arguing VM isolation is your real security boundary. That's true, but I'd rather have both layers.

## What's OpenClaw and why should you care about isolation

OpenClaw is an AI agent with full shell access, filesystem read/write, and persistent memory. You talk to it via Telegram (or other channels), and it can execute commands on your server. That's the whole point, and that's also why you don't run it on your main machine.

Hundreds of instances have been found exposed on the internet without authentication. Read the disclaimer in the script before running it.

## What the script does

1. Updates the system
2. Installs build dependencies (auto-detects KVM for guest agent)
3. Creates a 2GB swapfile (Ubuntu Server + LVM doesn't make one, and npm _will_ OOM without it)
4. Installs Node.js 24
5. Creates a dedicated `openclaw` user with no password
6. Grants temporary sudo, installs OpenClaw globally
7. Enables systemd lingering so the service survives logout
8. **Revokes sudo** — the `openclaw` user ends up with no privileged access
9. **Locks down the network** — the VM can only reach the default gateway (for internet) and nothing else on the LAN

## Requirements

- Ubuntu 24.04 LTS Server (fresh install)
- Root or sudo access
- Internet connection
- Something like 2 cores, 4GB RAM, 32GB disk

## Usage

```bash
git clone https://github.com/MundoFacu/openclaw-vm-setup.git
cd openclaw-vm-setup
chmod +x setup_openclaw.sh
sudo ./setup_openclaw.sh
```

## After the script finishes

There are a few things you need to do by hand because they require interactive input (API keys, bot tokens, pairing codes).

**Switch to the openclaw user and run onboarding:**

```bash
sudo su - openclaw
export XDG_RUNTIME_DIR=/run/user/$(id -u)
openclaw onboard
```

Pick Local gateway, loopback bind (127.0.0.1), Node runtime. Have your AI provider API key and Telegram bot token ready. If you need a Telegram bot, talk to `@BotFather`, create one, disable privacy mode via `/setprivacy`, and grab your user ID from `@userinfobot`.

**Start the daemon:**

```bash
openclaw daemon install
systemctl --user daemon-reload
systemctl --user enable --now openclaw-gateway
```

**Run the security audit:**

```bash
openclaw security audit --deep
openclaw security audit --fix
```

**Pair your bot:**

Send any message to your bot on Telegram. You'll get a pairing code. Then:

```bash
openclaw pairing list telegram
openclaw pairing approve telegram <CODE>
```

**Take a VM snapshot.** Do it now, before the agent touches anything.

## Network hardening

The script auto-detects your default gateway and local subnet, then sets up iptables rules so the VM can only reach the gateway (for internet via NAT) and nothing else on the LAN. No port scanning, no lateral movement.

What's allowed:
- Loopback (OpenClaw gateway binds to 127.0.0.1)
- Established/related connections (so your SSH session doesn't drop)
- Traffic to the default gateway (internet access)

What's blocked:
- Everything else on the local subnet

Rules are persisted across reboots via `iptables-persistent`. To verify:

```bash
# should work (internet via gateway):
curl -s https://api.telegram.org --max-time 5

# should fail (LAN blocked):
ping -c1 -W2 192.168.1.100
```

To inspect or modify the rules:

```bash
sudo iptables -L OUTPUT -v -n          # see current rules
sudo iptables -D OUTPUT -d <subnet> -j DROP  # remove a rule (careful)
sudo netfilter-persistent save         # persist changes
```

If you need the VM to reach a specific LAN host (e.g., a local LLM server), add an allow rule _before_ the subnet drop:

```bash
sudo iptables -I OUTPUT 4 -d 192.168.1.50 -j ACCEPT
sudo netfilter-persistent save
```

## Useful commands

```bash
systemctl --user status openclaw-gateway      # is it running?
systemctl --user restart openclaw-gateway     # restart
journalctl --user -u openclaw-gateway -f      # live logs
openclaw doctor                               # something broken?
openclaw status                               # general health
```

## Common issues

- **OOM during install** — add more swap or bump VM RAM
- **Service won't start** — run `openclaw doctor --fix`
- **Bot ignores you** — check `openclaw pairing list telegram`, you probably need to approve
- **"No API key"** — `openclaw configure --section model`
- **Port 18789 busy** — `lsof -nP -iTCP:18789 -sTCP:LISTEN`

## License

MIT
