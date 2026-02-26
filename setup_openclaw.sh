#!/usr/bin/env bash
# setup_openclaw.sh
# Prepares a fresh Ubuntu Server VM for running OpenClaw safely.
#
# Based on Nightly Ventures' guide but adapted for any hypervisor
# and with one important change: sudo gets revoked after install.
# https://www.nightlyventures.com/p/self-host-moltbot-on-proxmox
#
# -------------------------------------------------------------------
# DISCLAIMER
# -------------------------------------------------------------------
# OpenClaw is an AI agent with full shell access. It can run commands,
# read and write files, install packages, and reach the internet.
# It has persistent memory between sessions, so it remembers things.
#
# That's powerful, but it also means a prompt injection, a bug, or
# just a poorly worded instruction could make it do things you didn't
# intend. Hundreds of instances have already been found exposed on
# the internet without any authentication. Don't be one of them.
#
# This script does what it can:
#   - Runs OpenClaw under its own user, not yours
#   - Gives it sudo only during setup, then takes it away
#   - Sets up swap so npm doesn't OOM during install
#
# But the real protection is the VM itself. If something goes wrong,
# you delete the VM and restore a snapshot. So:
#   - Always run this in an isolated VM
#   - Take snapshots before and after
#   - Bind the gateway to loopback only (127.0.0.1)
#   - Don't expose any ports to your network
#
# You run this, you own the risk. Fair enough? Let's go.
# -------------------------------------------------------------------
#
# Usage:
#   chmod +x setup_openclaw.sh
#   sudo ./setup_openclaw.sh
#
# Tested on Ubuntu 24.04 LTS Server. Should work on 22.04 too
# but I haven't tried it.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[ok]${NC} $1"; }
warn() { echo -e "${YELLOW}[!!]${NC} $1"; }
err()  { echo -e "${RED}[err]${NC} $1" >&2; }

# -- sanity checks --

if [[ $EUID -ne 0 ]]; then
    err "Run this with sudo."
    exit 1
fi

if ! grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
    warn "Not Ubuntu — might work, might not. Continuing."
fi

OPENCLAW_USER="openclaw"
SWAP_SIZE="2G"
NODE_MAJOR=24

echo ""
echo -e "${RED}--- WARNING ---${NC}"
echo "You're about to install an AI agent with shell access."
echo "Read the disclaimer at the top of this script if you haven't."
echo ""
read -rp "Continue? (y/N): " confirm
if [[ ! "$confirm" =~ ^[yY]$ ]]; then
    echo "Okay, nothing happened."
    exit 0
fi

# -- 1. system update --

echo ""
echo -e "${CYAN}Updating system...${NC}"
apt update && apt upgrade -y
log "System up to date"

# -- 2. dependencies --

echo ""
echo -e "${CYAN}Installing build deps...${NC}"
apt install -y curl git build-essential ca-certificates gnupg

# only install guest agent if we're actually on KVM
if systemd-detect-virt -q 2>/dev/null && [[ "$(systemd-detect-virt)" == "kvm" ]]; then
    apt install -y qemu-guest-agent
    systemctl enable --now qemu-guest-agent
    log "qemu-guest-agent installed (KVM detected)"
else
    log "Not KVM, skipping guest agent"
fi

# -- 3. swap --
# Ubuntu Server with LVM doesn't create swap by default.
# npm install compiles native modules and WILL eat your RAM.

echo ""
echo -e "${CYAN}Setting up swap...${NC}"
if [[ -f /swapfile ]]; then
    warn "Swap already exists, skipping"
else
    fallocate -l "$SWAP_SIZE" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    log "${SWAP_SIZE} swap ready"
fi

# -- 4. node.js --

echo ""
echo -e "${CYAN}Installing Node.js ${NODE_MAJOR}...${NC}"
if command -v node &>/dev/null && node --version | grep -q "v${NODE_MAJOR}"; then
    warn "Node $(node --version) already there, skipping"
else
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    apt install -y nodejs
fi
log "node $(node --version), npm $(npm --version)"

# -- 5. dedicated user --
# We don't want openclaw running as root or as our admin user.
# If something goes sideways, damage stays contained.

echo ""
echo -e "${CYAN}Creating user '${OPENCLAW_USER}'...${NC}"
if id "$OPENCLAW_USER" &>/dev/null; then
    warn "User already exists, moving on"
else
    adduser --disabled-password --gecos "" "$OPENCLAW_USER"
    log "User '${OPENCLAW_USER}' created (no password)"
fi

# Temporarily give it sudo so npm/openclaw can do their thing.
# We take this away at the end — see the hardening section below.
usermod -aG sudo "$OPENCLAW_USER"
echo "${OPENCLAW_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${OPENCLAW_USER}"
chmod 440 "/etc/sudoers.d/${OPENCLAW_USER}"
warn "Temporary sudo for '${OPENCLAW_USER}' — gets revoked later"

# -- 6. install openclaw --

echo ""
echo -e "${CYAN}Installing OpenClaw...${NC}"
npm install -g openclaw@latest
OPENCLAW_VERSION=$(su - "$OPENCLAW_USER" -c "openclaw --version" 2>/dev/null || echo "?")
log "OpenClaw ${OPENCLAW_VERSION}"

# -- 7. systemd lingering --
# So the service keeps running after we log out of the openclaw user.

echo ""
echo -e "${CYAN}Enabling lingering...${NC}"
loginctl enable-linger "$OPENCLAW_USER"
log "Lingering enabled"

# -- hardening: revoke sudo --
#
# The original guide leaves NOPASSWD sudo permanently because
# "VM isolation is your real security layer". Fair point, but I'd
# rather have both. If someone pops the agent, at least they can't
# apt install whatever they want or mess with systemd.

echo ""
echo -e "${CYAN}Revoking sudo...${NC}"
rm -f "/etc/sudoers.d/${OPENCLAW_USER}"
gpasswd -d "$OPENCLAW_USER" sudo 2>/dev/null || true
log "Sudo revoked for '${OPENCLAW_USER}'"

# -- done --

echo ""
echo -e "${GREEN}--- Done ---${NC}"
echo ""
echo "Now you need to do a few things manually:"
echo ""
echo "  1. Switch to the openclaw user and run the onboarding wizard:"
echo ""
echo "       sudo su - openclaw"
echo "       export XDG_RUNTIME_DIR=/run/user/\$(id -u)"
echo "       openclaw onboard"
echo ""
echo "     Pick: Local gateway, loopback bind, Node runtime."
echo "     Have your API key and Telegram bot token ready."
echo ""
echo "  2. Set up the daemon:"
echo ""
echo "       openclaw daemon install"
echo "       systemctl --user daemon-reload"
echo "       systemctl --user enable --now openclaw-gateway"
echo ""
echo "  3. Run the security audit:"
echo ""
echo "       openclaw security audit --deep"
echo "       openclaw security audit --fix"
echo ""
echo "  4. Pair your Telegram bot (or whatever channel you chose):"
echo ""
echo "       openclaw pairing list telegram"
echo "       openclaw pairing approve telegram <CODE>"
echo ""
echo "  5. Take a VM snapshot. Seriously, do it now."
echo ""
echo -e "${YELLOW}Remember: '${OPENCLAW_USER}' has no sudo anymore.${NC}"
echo "Use your admin user for anything that needs root."
echo ""
