# Cheat sheet

Everything you normally need. For the *why*, see [README.md](README.md).

---

## Run it

`./bootstrap.sh` always works — new machine or old, it is the only command
you need to remember.

**First time on a machine:**

```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/HalcoDraco/ubuntu-autoinstall.git
cd ubuntu-autoinstall && ./bootstrap.sh
```

**Every time after that:**

```bash
cd ~/Documents/ubuntu-autoinstall
git pull
./bootstrap.sh --check --diff    # dry run - changes nothing
./bootstrap.sh                   # apply
```

Once it has run once, `make check` and `make run` do the same thing with less
typing. They only work *after* the first run, because `make` is not installed
on a fresh Ubuntu — that is the only difference between them.

Never use `sudo ./bootstrap.sh`. Run it as yourself; it asks for your password.

**Afterwards:** log out and back in (keyboard, docker group), and open a new
terminal (`java`).

---

## Add or remove an app

Edit **`group_vars/all.yml`** only. One line each.

```yaml
apt_packages:          # normal Ubuntu apps
  - vlc
  - btop
  - whatever-you-want  # <- add here

snap_packages:         # snaps
  - spotify
  - another-snap       # <- add here

snap_packages_classic: []   # snaps that need --classic (editors, IDEs)
  # - code
```

Then `make run`. Removing a line does **not** uninstall it — remove it
yourself with `sudo apt remove <name>`.

Not sure which list? Try `apt-cache policy <name>`. If it shows a version,
it's an apt package. Otherwise try `snap find <name>`.

---

## Turn a whole feature off

In `group_vars/all.yml` (everywhere) or `host_vars/<hostname>.yml` (one machine):

```yaml
install_chrome: false
install_vscode: false          # visual studio code
install_docker: false
install_mise: false            # java
install_nvidia_container: false  # gpu in docker
configure_keyboard: false
```

---

## Change the keyboard

**Which layouts, and the switch key** — `group_vars/all.yml`:

```yaml
keyboard_layouts:        # first one = the one you get at login
  - custom               # your US + Spanish-AltGr layout
  - es
keyboard_switch_keys: ["<Super>space"]
```

**The actual key mappings** — `roles/keyboard/files/custom`.
Each line is `[ normal, Shift, AltGr, AltGr+Shift ]`:

```
key <AC10> {[ semicolon, colon, ntilde, Ntilde ]};   // AltGr+; = ñ
```

To find a key's code, run `wev` and press it. To find a character's name,
search `/usr/include/X11/keysymdef.h` (drop the `XK_` prefix).

Then `make run` **and log out and back in** — GNOME only reads the layout at login.

---

## Machines with and without an NVIDIA card

**Nothing to do.** The playbook checks the PCI bus itself: a machine with a
card gets the driver and GPU-container support, a machine without one skips
both. The same configuration works everywhere.

The run tells you which happened:

```
NVIDIA GPU detected: True  (NVIDIA roles will run)
NVIDIA GPU detected: False (NVIDIA roles will be skipped)
```

To stop a machine that *has* a card from getting the proprietary driver, set
`nvidia_gpu_present: false`.

## Settings for one machine only (rarely needed)

Create `host_vars/<hostname>.yml` (run `hostname` for the name):

```yaml
install_docker: false     # example: skip docker on this machine
```

No file? It falls back to `host_vars/default.yml`, which is empty — so
`group_vars/all.yml` applies everywhere. That is the normal case.

---

## Run just one part

```bash
make run-tags TAGS=docker
```

Tags: `base` `packages` `chrome` `vscode` `docker` `nvidia`
`nvidia_container` `mise` `keyboard` `manual_steps`

---

## Java

```yaml
mise_tools:
  java: "latest"     # or "lts"
  # node: "latest"   # add other languages the same way
```

Installs once; it won't jump to a newer JDK on later runs.
To upgrade: `mise upgrade java`.

---

## Test changes safely first

```bash
make vm-create && make vm-start   # throwaway Ubuntu VM
make vm-run                       # run the playbook in it
make vm-reset                     # wipe it clean again
```

Change the Ubuntu version it tests in `vm/vm.env`
(`noble` = 24.04, `resolute` = 26.04, `jammy` = 22.04).

---

## If privileged tasks hang on Ubuntu 26.04

Symptom: `Timed out waiting for become success or become password prompt`.

26.04's default `sudo` (sudo-rs) does not print the prompt Ansible expects.
The playbook detects this and switches to classic sudo automatically. If it
tells you classic sudo is missing:

```bash
sudo apt install -y sudo
```

## If something breaks

```bash
make lint          # checks the files are valid
git diff           # what you changed
git checkout .     # undo your changes
```

Undo the keyboard change:

```bash
gsettings set org.gnome.desktop.input-sources sources "[('xkb','es'),('xkb','us')]"
```
