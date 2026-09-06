#!/usr/bin/env bash
# ===========================================================================
# vm-create.sh -- build a disposable Ubuntu VM to test this playbook against.
#
# WHY A VM AT ALL:
# Your daily driver is already configured, so running the playbook here proves
# almost nothing -- every task would report "ok" because the work is already
# done. A clean VM is the only way to test the from-scratch paths.
#
# WHY PLAIN QEMU AND NOT libvirt/virt-manager:
#   * No libvirt daemon, and no "libvirt" group membership -- which means no
#     logging out and back in before you can use it.
#   * /dev/kvm is already accessible to you via a systemd-logind ACL
#     (getfacl /dev/kvm shows user:pablo:rw-), so no kvm group either.
#   * Snapshots become trivial: the disk is a qcow2 OVERLAY on top of a
#     read-only base image, so "revert to clean" is just deleting the overlay.
#     That is faster and harder to get wrong than libvirt snapshots.
#
# WHY A CLOUD IMAGE AND NOT THE DESKTOP ISO:
# The desktop ISO is ~6 GB and requires clicking through a graphical
# installer. The cloud image is ~600 MB and boots unattended via cloud-init,
# so this script can build the whole VM without you touching anything.
# Run `./vm/vm-helper.sh desktop` afterwards to add GNOME for testing the
# keyboard and gsettings roles.
# ===========================================================================
set -euo pipefail

VM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The Ubuntu release to test against. Override to test 26.04 when it is out:
#   UBUNTU_RELEASE=<codename> ./vm/vm-create.sh
UBUNTU_RELEASE="${UBUNTU_RELEASE:-noble}"

BASE_IMG="${VM_DIR}/base-${UBUNTU_RELEASE}.img"
DISK="${VM_DIR}/disk.qcow2"
SEED="${VM_DIR}/seed.iso"
SSH_KEY="${VM_DIR}/id_ed25519"
DISK_SIZE="${DISK_SIZE:-24G}"
VM_MEM="${VM_MEM:-4096}"
VM_CPUS="${VM_CPUS:-4}"
SSH_PORT="${SSH_PORT:-2222}"
VM_USER="${VM_USER:-pablo}"

say()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- dependency check ------------------------------------------------------
missing=()
for cmd in qemu-system-x86_64 qemu-img cloud-localds ssh-keygen; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if (( ${#missing[@]} )); then
    die "Missing commands: ${missing[*]}
       Install them with:
         sudo apt install -y qemu-system-x86 qemu-utils cloud-image-utils"
fi

[[ -w /dev/kvm ]] || die "/dev/kvm is not writable by you. KVM acceleration is required."

# --- ssh key ---------------------------------------------------------------
# A dedicated key for the throwaway VM. Never reuse your real key for a
# machine whose whole purpose is to be destroyed and rebuilt.
if [[ ! -f "$SSH_KEY" ]]; then
    say "Generating a dedicated SSH key for the test VM"
    ssh-keygen -t ed25519 -N '' -f "$SSH_KEY" -C "ubuntu-autoinstall-testvm" >/dev/null
fi

# --- base image ------------------------------------------------------------
if [[ ! -f "$BASE_IMG" ]]; then
    say "Downloading the Ubuntu ${UBUNTU_RELEASE} cloud image (~600 MB, once)"
    curl -fL --progress-bar \
        "https://cloud-images.ubuntu.com/${UBUNTU_RELEASE}/current/${UBUNTU_RELEASE}-server-cloudimg-amd64.img" \
        -o "${BASE_IMG}.part"
    mv "${BASE_IMG}.part" "$BASE_IMG"
else
    say "Base image already present: $(basename "$BASE_IMG")"
fi

# --- cloud-init seed -------------------------------------------------------
# This is what makes the install unattended: cloud-init reads it on first boot
# and creates the user, installs the SSH key, and enables password-less sudo.
say "Building the cloud-init seed"
cat > "${VM_DIR}/user-data" <<EOF
#cloud-config
hostname: autoinstall-test
# NOTE: this hostname deliberately does NOT match any host_vars file, so the
# VM exercises the host_vars/default.yml fallback path -- which is exactly
# what a freshly installed machine will hit.

users:
  - name: ${VM_USER}
    groups: [sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    ssh_authorized_keys:
      - $(cat "${SSH_KEY}.pub")

package_update: true
packages:
  - ansible
  - git

# Make the console usable if you ever attach to it for debugging.
ssh_pwauth: false
EOF
printf 'instance-id: autoinstall-test\nlocal-hostname: autoinstall-test\n' > "${VM_DIR}/meta-data"
cloud-localds "$SEED" "${VM_DIR}/user-data" "${VM_DIR}/meta-data"

# --- overlay disk ----------------------------------------------------------
# The overlay is the snapshot mechanism. base-*.img is never written to, so
# `vm-helper.sh reset` just deletes and recreates this file.
if [[ -f "$DISK" ]]; then
    say "Disk already exists. Use './vm/vm-helper.sh reset' to wipe it, or 'destroy' to start over."
else
    say "Creating a ${DISK_SIZE} overlay disk on top of the read-only base image"
    qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMG" "$DISK" "$DISK_SIZE" >/dev/null
fi

say "VM created. Start it with:  ./vm/vm-helper.sh start"
printf '     SSH:      ./vm/vm-helper.sh ssh      (or ssh -p %s -i %s %s@localhost)\n' \
       "$SSH_PORT" "$SSH_KEY" "$VM_USER"
printf '     Reset:    ./vm/vm-helper.sh reset    (instant revert to clean)\n'
