#!/usr/bin/env bash
# ===========================================================================
# bootstrap.sh -- get a brand-new Ubuntu machine from "nothing" to "configured".
#
# Usage on a fresh install:
#
#     sudo apt update && sudo apt install -y git
#     git clone https://github.com/HalcoDraco/ubuntu-autoinstall.git
#     cd ubuntu-autoinstall && ./bootstrap.sh
#
# Or, without cloning first (the ansible-pull path):
#
#     sudo apt update && sudo apt install -y ansible git
#     ansible-pull -U https://github.com/HalcoDraco/ubuntu-autoinstall.git -K local.yml
#
# WHY THIS SCRIPT EXISTS AT ALL, given ansible-pull works:
# ansible-pull does NOT install requirements.yml -- I checked its source. It
# clones the repo and runs the playbook, nothing more. The Ubuntu `ansible`
# package happens to bundle community.general so the pull path works today,
# but that is luck, not design. This script installs dependencies explicitly.
# ===========================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

say() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- refuse to run as root -------------------------------------------------
# This matters more than it looks. The playbook configures your GNOME desktop
# via dconf, which must run as YOU. If the whole thing runs as root, those
# tasks write root's settings: no error, no effect, very confusing.
# We escalate per-task with sudo instead, which is why you get a password
# prompt rather than being asked to run this with sudo.
if [[ "${EUID}" -eq 0 ]]; then
    die "Do not run this as root or with sudo.
       Run it as your normal user; it will ask for your sudo password when
       it needs one. See the 'become' explanation in local.yml."
fi

# --- sanity: this is Ubuntu ------------------------------------------------
if ! grep -qi ubuntu /etc/os-release 2>/dev/null; then
    die "This repo targets Ubuntu only."
fi

# --- install ansible if missing --------------------------------------------
if ! command -v ansible-playbook >/dev/null 2>&1; then
    say "Installing ansible and git (needs sudo)"
    sudo apt-get update
    sudo apt-get install -y ansible git
else
    say "ansible already present: $(ansible --version | head -1)"
fi

# --- install pinned galaxy dependencies ------------------------------------
say "Installing pinned collections from requirements.yml"
ansible-galaxy install -r requirements.yml

# --- run ----------------------------------------------------------------
# -K  == --ask-become-pass: prompt once for the sudo password, so the tasks
#        that need root can escalate while everything else stays as you.
say "Running the playbook (you will be asked for your sudo password)"
exec ansible-playbook local.yml -K "$@"
