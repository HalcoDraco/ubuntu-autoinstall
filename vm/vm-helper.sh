#!/usr/bin/env bash
# ===========================================================================
# vm-helper.sh -- drive the test VM created by vm-create.sh.
#
#   start     boot the VM in the background
#   stop      shut it down cleanly
#   status    is it running?
#   ssh       open a shell inside it
#   run       run this repo's playbook inside it (the actual test)
#   desktop   install GNOME + autologin, so gsettings/keyboard can be tested
#   reset     revert to a pristine machine (deletes the overlay disk)
#   destroy   delete everything including the downloaded base image
# ===========================================================================
set -euo pipefail

VM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$VM_DIR")"

UBUNTU_RELEASE="${UBUNTU_RELEASE:-noble}"
BASE_IMG="${VM_DIR}/base-${UBUNTU_RELEASE}.img"
DISK="${VM_DIR}/disk.qcow2"
SEED="${VM_DIR}/seed.iso"
SSH_KEY="${VM_DIR}/id_ed25519"
PIDFILE="${VM_DIR}/qemu.pid"
LOGFILE="${VM_DIR}/console.log"
DISK_SIZE="${DISK_SIZE:-24G}"
VM_MEM="${VM_MEM:-4096}"
VM_CPUS="${VM_CPUS:-4}"
SSH_PORT="${SSH_PORT:-2222}"
VM_USER="${VM_USER:-pablo}"

say() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\n\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

ssh_cmd() {
    ssh -p "$SSH_PORT" -i "$SSH_KEY" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ConnectTimeout=5 \
        "${VM_USER}@localhost" "$@"
}

is_running() { [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

cmd_start() {
    is_running && { say "Already running (pid $(cat "$PIDFILE"))"; return 0; }
    [[ -f "$DISK" ]] || die "No disk. Run ./vm/vm-create.sh first."

    say "Booting the VM (headless, ${VM_CPUS} cpus, ${VM_MEM} MB)"
    # -netdev user with hostfwd is QEMU's user-mode networking: no bridges, no
    # root, no firewall rules. The VM reaches the internet, and localhost:2222
    # on the host maps to port 22 in the guest. That is all we need, and it is
    # why this harness needs no privileged setup at all.
    qemu-system-x86_64 \
        -name ubuntu-autoinstall-test \
        -machine q35,accel=kvm \
        -cpu host \
        -smp "$VM_CPUS" \
        -m "$VM_MEM" \
        -drive "file=${DISK},if=virtio,format=qcow2" \
        -drive "file=${SEED},if=virtio,format=raw,readonly=on" \
        -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" \
        -device virtio-net-pci,netdev=net0 \
        -device virtio-vga \
        -display none \
        -serial "file:${LOGFILE}" \
        -daemonize \
        -pidfile "$PIDFILE"

    say "Waiting for SSH on port ${SSH_PORT} (first boot runs cloud-init, ~60-90s)"
    for i in $(seq 1 90); do
        if ssh_cmd true 2>/dev/null; then
            say "VM is up. Shell:  ./vm/vm-helper.sh ssh"
            return 0
        fi
        sleep 2
        printf '.'
    done
    die "Timed out. Check the console log: tail -50 ${LOGFILE}"
}

cmd_stop() {
    is_running || { say "Not running."; return 0; }
    say "Shutting down"
    ssh_cmd sudo poweroff 2>/dev/null || true
    for _ in $(seq 1 30); do is_running || break; sleep 1; done
    is_running && { kill "$(cat "$PIDFILE")" 2>/dev/null || true; sleep 2; }
    rm -f "$PIDFILE"
    say "Stopped."
}

cmd_status() {
    if is_running; then
        echo "running (pid $(cat "$PIDFILE"))  ssh port ${SSH_PORT}"
    else
        echo "stopped"
    fi
}

cmd_ssh() { is_running || die "VM is not running. ./vm/vm-helper.sh start"; ssh_cmd "$@"; }

cmd_desktop() {
    is_running || die "VM is not running. ./vm/vm-helper.sh start"
    say "Installing GNOME inside the VM (~1.5 GB, several minutes)"
    # WHY: the cloud image is a server image with no GNOME, no D-Bus session
    # bus and no display manager. The keyboard and gsettings roles cannot be
    # tested without a real user session. Autologin gives us one on boot,
    # which is what makes those roles testable over SSH.
    ssh_cmd sudo DEBIAN_FRONTEND=noninteractive apt-get update
    ssh_cmd sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ubuntu-desktop-minimal
    say "Enabling autologin so a GNOME session (and its D-Bus bus) exists at boot"
    ssh_cmd "sudo install -d /etc/gdm3 && printf '[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=${VM_USER}\n' | sudo tee /etc/gdm3/custom.conf >/dev/null"
    say "Rebooting into the desktop"
    ssh_cmd sudo reboot || true
    sleep 10
    for _ in $(seq 1 90); do ssh_cmd true 2>/dev/null && break; sleep 2; printf '.'; done
    say "Desktop ready. Verify the session bus with:"
    printf '     ./vm/vm-helper.sh ssh "echo \$DBUS_SESSION_BUS_ADDRESS; loginctl list-sessions"\n'
}

cmd_run() {
    is_running || die "VM is not running. ./vm/vm-helper.sh start"
    say "Copying the repo into the VM"
    ssh_cmd "rm -rf ~/ubuntu-autoinstall && mkdir -p ~/ubuntu-autoinstall"
    tar -C "$REPO_DIR" --exclude=.git --exclude=.venv --exclude=vm -cf - . \
        | ssh_cmd "tar -C ~/ubuntu-autoinstall -xf -"
    say "Running the playbook inside the VM"
    # No -K needed: cloud-init gave this user password-less sudo in the VM.
    # On a real machine you WILL be prompted; that is intentional.
    ssh_cmd "cd ~/ubuntu-autoinstall && ansible-galaxy install -r requirements.yml && ansible-playbook local.yml ${*:-}"
}

cmd_reset() {
    say "Reverting to a pristine machine"
    is_running && cmd_stop
    rm -f "$DISK"
    qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMG" "$DISK" "$DISK_SIZE" >/dev/null
    say "Done. The overlay was deleted and recreated -- the VM is byte-for-byte clean."
    say "This is the mechanism to use when testing idempotency: reset, run, run again."
}

cmd_destroy() {
    is_running && cmd_stop
    say "Deleting all VM artefacts (including the downloaded base image)"
    rm -f "$DISK" "$SEED" "$PIDFILE" "$LOGFILE" \
          "${VM_DIR}/user-data" "${VM_DIR}/meta-data" "$BASE_IMG" \
          "$SSH_KEY" "${SSH_KEY}.pub"
    say "Gone."
}

case "${1:-}" in
    start)   shift; cmd_start "$@" ;;
    stop)    shift; cmd_stop "$@" ;;
    status)  shift; cmd_status "$@" ;;
    ssh)     shift; cmd_ssh "$@" ;;
    run)     shift; cmd_run "$@" ;;
    desktop) shift; cmd_desktop "$@" ;;
    reset)   shift; cmd_reset "$@" ;;
    destroy) shift; cmd_destroy "$@" ;;
    ip)      echo "localhost:${SSH_PORT} (QEMU user-mode networking port forward)" ;;
    *)       sed -n '3,16p' "$0" | sed 's/^# \?//' ;;
esac
