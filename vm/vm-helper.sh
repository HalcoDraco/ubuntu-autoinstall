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

# Optional local overrides (release, memory, cpus). Not in git.
# Create vm/vm.env with e.g.:  UBUNTU_RELEASE=resolute
[[ -f "${VM_DIR}/vm.env" ]] && . "${VM_DIR}/vm.env"

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

# SSH forwards the host's LANG/LC_* by default (/etc/ssh/ssh_config has
# "SendEnv LANG LC_*"). The minimal cloud image has no locales installed
# beyond C.UTF-8, so a host locale like es_ES.UTF-8 makes Ansible abort with
# "could not initialize the preferred locale". Forcing C.UTF-8 for every
# remote command avoids depending on what locales the guest happens to have.
ssh_cmd() {
    ssh -p "$SSH_PORT" -i "$SSH_KEY" \
        -o SetEnv=LC_ALL=C.UTF-8 \
        -o SetEnv=LANG=C.UTF-8 \
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
    say "Installing GNOME inside the VM (~1.5 GB, 10-20 minutes)"
    # WHY: the cloud image is a server image with no GNOME, no D-Bus session
    # bus and no display manager. The keyboard and gsettings roles cannot be
    # tested without a real user session. Autologin gives us one on boot.
    #
    # WHY systemd-run AND NOT A PLAIN ssh COMMAND:
    # Running a 15-minute apt directly over SSH means the install dies with
    # SIGHUP if the connection drops -- which can leave dpkg half-configured
    # and the VM unreachable. (That is exactly what happened the first time.)
    # systemd-run launches it as a transient unit owned by the VM's init, so
    # it survives disconnects and we can poll it independently.
    #
    # NEEDRESTART_SUSPEND=1 is the other half of the fix: installing a desktop
    # pulls in needrestart, which helpfully restarts systemd-networkd and
    # systemd-resolved -- severing the very SSH connection driving the install.
    # Suspending it keeps the network up.
    ssh_cmd "sudo systemctl reset-failed desktop-install 2>/dev/null; \
             sudo systemd-run --unit=desktop-install --collect \
               --setenv=DEBIAN_FRONTEND=noninteractive \
               --setenv=NEEDRESTART_SUSPEND=1 \
               bash -c 'apt-get update && apt-get install -y ubuntu-desktop-minimal'" >/dev/null

    say "Waiting for the install to finish (polling the unit, not holding a connection)"
    for i in $(seq 1 120); do
        state=$(ssh_cmd "systemctl show -p SubState --value desktop-install 2>/dev/null" 2>/dev/null || echo "unreachable")
        case "$state" in
            dead|failed) break ;;
            unreachable) printf 'x' ;;
            *) printf '.' ;;
        esac
        sleep 15
    done
    echo

    result=$(ssh_cmd "systemctl show -p Result --value desktop-install 2>/dev/null" 2>/dev/null || echo unknown)
    if ! ssh_cmd "test -x /usr/bin/gnome-shell" 2>/dev/null; then
        die "GNOME did not install (unit result: ${result}). Inspect with:
       ./vm/vm-helper.sh ssh 'journalctl -u desktop-install --no-pager | tail -40'"
    fi
    say "GNOME installed."

    say "Enabling autologin so a GNOME session (and its D-Bus bus) exists at boot"
    ssh_cmd "sudo install -d /etc/gdm3 && printf '[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=${VM_USER}\n' | sudo tee /etc/gdm3/custom.conf >/dev/null"

    say "Rebooting into the desktop"
    ssh_cmd "sudo systemd-run --on-active=1 --collect systemctl reboot" >/dev/null 2>&1 || true
    sleep 20
    for _ in $(seq 1 60); do ssh_cmd true 2>/dev/null && break; sleep 5; printf '.'; done
    echo
    say "Desktop ready. Session check:"
    ssh_cmd "loginctl list-sessions --no-legend 2>/dev/null | head -3; echo '--- gnome-shell running? ---'; pgrep -c gnome-shell || echo 0"
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
    # Mirror bootstrap.sh: only fetch from galaxy when the collection is
    # genuinely absent. Installing the pinned newer community.general on top
    # of Ubuntu's bundled one breaks ansible 2.10 on 22.04.
    ssh_cmd "cd ~/ubuntu-autoinstall && \
             { ansible-doc community.general.snap >/dev/null 2>&1 \
               || ansible-galaxy install -r requirements.yml; } && \
             ansible-playbook local.yml ${*:-}"
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
