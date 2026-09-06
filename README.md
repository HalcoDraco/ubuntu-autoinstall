# ubuntu-autoinstall

Ansible automation that takes a freshly installed Ubuntu desktop and converges it
to my preferred state. Built to run unchanged on **Ubuntu 22.04, 24.04 and 26.04**, and to be re-run periodically on every machine rather than only
after a reinstall.

---

## 1. Bootstrap: the one command

On a brand-new machine:

```bash
sudo apt update && sudo apt install -y ansible git
ansible-pull -U https://github.com/HalcoDraco/ubuntu-autoinstall.git -K local.yml
```

Or, if you would rather clone first (recommended — it is easier to inspect
before it runs, and `bootstrap.sh` installs dependencies explicitly):

```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/HalcoDraco/ubuntu-autoinstall.git
cd ubuntu-autoinstall && ./bootstrap.sh
```

> **Run it as yourself, never with `sudo`.**
> `bootstrap.sh` refuses to start as root, and that is deliberate — see
> [§6, the `become` trap](#6-the-become-trap-the-thing-that-will-bite-you).

Everyday use, once cloned:

```bash
make            # list every target
make check      # dry run: show what WOULD change, change nothing
make run        # apply
make run-tags TAGS=keyboard      # apply one part only
make lint       # ansible-lint, production profile
```

---

## 2. A 10-minute Ansible primer

Enough vocabulary to maintain this repo. Concepts appear in the order you meet
them in `local.yml`.

| Term | What it actually is |
|---|---|
| **Module** | A unit of work with a proper interface, e.g. `ansible.builtin.apt`. Modules are *idempotent*: they check the current state and only act if needed. |
| **Task** | One invocation of a module, with a `name:` describing it. |
| **Play** | A block matching hosts to work. This repo has exactly one, in `local.yml`. |
| **Playbook** | A file containing plays. Ours is `local.yml`. |
| **Role** | A reusable bundle of tasks in `roles/<name>/`, with a conventional layout. |
| **Inventory** | The list of machines. Ours contains only `localhost`. |
| **Facts** | Auto-discovered information about the machine (`ansible_distribution_release`, `ansible_hostname`, …). Gathered before anything runs. |
| **Variables** | Settings. Layered by precedence — see below. |
| **Handler** | A task that runs only when notified, and only once at the end. Not used yet. |
| **Tag** | A label allowing `--tags docker` to run just one part. |
| **`become`** | "Use sudo for this." Read §6 before touching it. |

### The role layout

```
roles/chrome/
├── defaults/main.yml   # variables, LOWEST precedence — meant to be overridden
├── tasks/main.yml      # the actual work
├── files/              # files copied verbatim (roles/keyboard/files/custom)
├── templates/          # files with {{ variables }} substituted (none yet)
├── handlers/           # notified tasks (none yet)
└── meta/main.yml       # metadata and role dependencies
```

Ansible finds these by convention: `tasks/main.yml` is run automatically, and
`copy: src: custom` looks in that role's `files/` without you saying so.

### Variable precedence, the three levels this repo uses

Later beats earlier:

1. `roles/*/defaults/main.yml` — role fallbacks. Safe to override.
2. `group_vars/all.yml` — **your global configuration. This is the file you edit.**
3. `host_vars/<hostname>.yml` — per-machine overrides. Beats everything above.

So `nvidia_gpu_present` is `false` in `group_vars/all.yml` (safe default) and
`true` in `host_vars/Niaura-linux.yml` (this desktop has a GPU).

### Idempotency, the property that matters most

Every task must be a no-op when the system is already in the desired state.
That is what makes this safe to run weekly rather than only after a reinstall.
Run output tells you:

- `ok` — already correct, nothing done. **This is the goal on a second run.**
- `changed` — something was modified.
- `skipped` — a `when:` condition was false.

A task that reports `changed` on every run is a bug, even when harmless. It
means you can no longer tell real drift from noise.

---

## 3. Adding an application (the common case)

Edit **`group_vars/all.yml`** and nothing else:

```yaml
apt_packages:
  - vlc
  - htop
  - your-new-package     # <- one line

snap_packages:
  - spotify
  - your-new-snap        # <- one line

snap_packages_classic: []
  # - code               # snaps needing --classic go here instead
```

Then `make run`.

**When does an app need a role instead of a list entry?** Only when it needs
logic: a third-party apt repo, a signing key, a group membership, a config
file. VLC is one package name from Ubuntu's own repo, so it is a list entry.
Chrome needs a repo and a key, so it is a role. Spotify is one snap name, so
it is a list entry too — the same test, applied consistently.

---

## 4. Per-machine differences

One playbook, different variables — never a forked playbook.

```
host_vars/
├── Niaura-linux.yml       # the desktop: nvidia_gpu_present: true
├── example-laptop.yml     # TEMPLATE — rename to the laptop's `hostname`
└── default.yml            # fallback for any machine with no file of its own
```

To onboard the laptop: run `hostname` on it, rename `example-laptop.yml` to
exactly that, commit.

### Why the inventory is just `localhost`

The obvious design is to list every machine in the inventory and let Ansible
auto-load `host_vars/<hostname>.yml`. I deliberately did not, for two reasons
found by reading `ansible/cli/pull.py`:

1. **`ansible-pull` always limits the run to `localhost,<fqdn>,127.0.0.1`.**
   If both `localhost` and `Niaura-linux` were in the inventory, both would
   match that limit and the entire playbook would run **twice**.
2. **A fresh machine has whatever hostname you typed into the installer.** If
   that name is not in the inventory, `ansible-pull` matches nothing and
   silently does nothing — the worst possible failure for a tool whose job is
   setting up new machines.

So `local.yml` loads `host_vars/<hostname>.yml` itself via `first_found`,
falling back to `default.yml`. You keep per-machine variance; an unknown
machine gets safe defaults instead of a silent no-op.

---

## 5. Staying version-agnostic

Hard rules for this repo. Breaking one is how it rots on the next release.

| Rule | Do | Never |
|---|---|---|
| Codenames | `suites: "{{ ansible_distribution_release }}"` | `suites: noble` |
| Package names | `openjdk` via mise, `default-jdk` | `openjdk-25-jdk` |
| Repos | Official upstream apt repos | PPAs — they break across upgrades |
| Ansible features | Only what 22.04's ansible 2.10 has | `deb822_repository` (needs core 2.15+, absent on 22.04) |
| Facts | `ansible_facts['distribution_release']` | `ansible_distribution_release` — removed in ansible-core 2.24 |
| Release-specific work | `when: ansible_distribution_version is version('26.04', '>=')` | Assuming a release |

### Why repo files are written with `template`

Ansible has a purpose-built module for apt repositories, and this repo uses
neither of the two options:

- `apt_repository` writes the **deprecated one-line format** that APT 3
  (26.04) warns about.
- `deb822_repository` writes the modern format but **needs ansible-core
  2.15+**. Ubuntu 22.04 ships ansible 2.10, so the module does not exist
  there and the role would fail outright.

A `template` has neither problem: it produces the modern deb822 format on
every Ansible version from 22.04's through 26.04's. Idempotency is unaffected
— `template` compares checksums, so it is a no-op when the file already
matches.

Three of the four repos used here (Chrome, mise, Spotify's snap) have **no
codename at all** — they publish a single `stable` suite for every Ubuntu
release, so they cannot rot. Docker's does need the codename, which is exactly
why it is written as the fact and never as a literal.

> **Verified on 26.04.** The playbook has been run against a real Ubuntu
> 26.04 "Resolute Raccoon" VM (APT 3.2.0, ansible-core 2.20.1): it completes
> with zero failures, and the snap-prompting checklist entry correctly appears
> there while staying hidden on 24.04.

### What is different about 26.04, and how it is handled

| 26.04 change | Consequence | Handling |
|---|---|---|
| **Wayland-only** | `setxkbmap`/`xkbcomp` do not work at all | All desktop config goes through gsettings/dconf. Neither tool appears anywhere in this repo. |
| **GNOME 50** | dconf schema paths are stable across versions | No change needed |
| **APT 3** | one-line `.list` sources deprecated | Repo files written as modern `.sources` (deb822) via `template` |
| **Snap prompting on** | first launch of a confined snap shows a dialog | Cannot be scripted; on the manual-steps checklist, printed only when running on 26.04+ |

This machine is **already on Wayland** under 24.04, so the keyboard constraint
is live today rather than a future surprise.

---

## 6. The `become` trap (the thing that will bite you)

`local.yml` sets `become: false` for the whole play, and individual tasks opt
into root with `become: true`. This is the most important design decision in
the repo.

**Why:** GNOME settings live in *your* user's dconf database and need *your*
session's D-Bus. Run them as root and you configure root's desktop — no error,
no warning, no effect, and a genuinely confusing afternoon.

**The consequence:**

```bash
ansible-playbook local.yml -K        # CORRECT: runs as you, sudo per task
sudo ansible-playbook local.yml      # WRONG: everything runs as root
```

`become: false` **cannot climb back down** to your user once you have started
as root. If you launch the playbook with `sudo`, the keyboard role silently
writes root's settings and your desktop never changes. `-K`
(`--ask-become-pass`) prompts once for your sudo password and hands it to the
tasks that need it.

The same applies to `ansible-pull`: use `-K`, not `sudo ansible-pull`. And it
is why running this from cron needs care — a cron job has no session bus, so
the dconf tasks cannot work there at all.

---

## 7. Testing safely in a VM

Your daily driver is already configured, so running the playbook on it proves
almost nothing — everything reports `ok` because the work is already done. A
clean VM is the only way to test the from-scratch paths.

**One-time setup:**

```bash
sudo apt install -y qemu-system-x86 qemu-utils cloud-image-utils
```

That is the *only* privileged step, and it needs **no group membership and no
logging out** — `/dev/kvm` is already yours via a systemd-logind ACL (check
with `getfacl /dev/kvm`).

```bash
make vm-create     # download the cloud image, build the disk (~600 MB, once)
make vm-start      # boot, unattended, ~60-90s
make vm-run        # copy this repo in and run the playbook
make vm-desktop    # add GNOME + autologin, to test keyboard/gsettings
make vm-reset      # instant revert to pristine
make vm-destroy    # delete everything
```

**Why plain QEMU rather than libvirt/virt-manager:** no daemon, no `libvirt`
group, no logout. The disk is a qcow2 **overlay** on a read-only base image, so
"revert to clean" is just deleting the overlay — faster and harder to get
wrong than libvirt snapshots.

**Testing idempotency, the thing that actually matters:**

```bash
make vm-reset && make vm-start
make vm-run        # first run:  lots of "changed"
make vm-run        # second run: must be ALL "ok", zero "changed"
```

Any task reporting `changed` on the second run is a bug. That is the test.

**What a VM still cannot test:** the real NVIDIA driver (no passthrough GPU),
Secure Boot MOK enrollment, and anything requiring an OAuth browser login.
Those are on the manual checklist precisely because nothing can automate them.

**Why not a container:** an LXC/Docker container has no GNOME session, no
D-Bus user bus and no GPU, so the keyboard, gsettings and NVIDIA roles are all
untestable. It would only cover the apt layer.

---

## 8. What is implemented

| Role | Tag | Status |
|---|---|---|
| `base` | `base` | **Done** — python3/pip/venv, apt cache, essentials |
| `packages` | `packages`, `apt`, `snap` | **Done** — the user-editable lists (VLC, Spotify) |
| `chrome` | `chrome` | **Done** — Google's repo + the `repo_add_once` fix |
| `keyboard` | `keyboard` | **Done** — your 14 real key mappings, compile-verified |
| `manual_steps` | `manual_steps` | **Done** — prints the checklist |
| `docker` | `docker` | **Done** — Docker Engine from Docker's repo, user added to `docker` group |
| `nvidia` | `nvidia` | **Done** — `ubuntu-drivers install`, triple-guarded |
| `mise` | `mise` | **Done** — latest JDK, no version hardcoded |

**Firefox is deliberately left untouched.** Nothing in this repo removes,
modifies or reconfigures it.

### Java / mise

`mise` installs the newest JDK at the time it runs — nothing names a version,
so this cannot rot. The tool list is `mise_tools` in `group_vars/all.yml`:

```yaml
mise_tools:
  java: "latest"     # or "lts" if you prefer long-term-support releases
```

Adding another language later is a one-line edit there (`node: "latest"`).

Two things worth knowing:

- **`java` appears in new terminals, not your current one.** The shims are
  added to `PATH` via `~/.profile`, which is read at login. This is
  deliberate: a `~/.bashrc` hook (what `mise activate` installs) only affects
  terminals, so apps launched from the GNOME menu would not find Java.
- **It installs the latest JDK once; it does not chase new releases.** The
  role only installs a tool that is missing, so re-running will not silently
  swap your JDK. To move to a newer one: `mise upgrade java`.
- A mise JDK is a **user-level** install. `java` works, but an apt package
  declaring `Depends: default-jre` will not see it. If you ever need that, add
  a system JDK to `apt_packages`.

### Docker

Docker Engine (not Docker Desktop) from Docker's official repository, with
your user added to the `docker` group so `sudo` is not needed.

> **The `docker` group grants effective root.** Any member can run
> `docker run -v /:/host ...` and edit any file on the system. That is the
> standard trade-off for password-less Docker, but it is worth knowing rather
> than discovering.

You must **log out and back in** before `docker` works without `sudo` — group
membership is only read when a session starts. The playbook tells you this,
but only when the membership actually changed.

The role checks that Docker publishes a repo for your Ubuntu release before
writing anything. Docker can lag weeks behind a new release; without that
check the failure is a broken source file that breaks every later `apt`
command.

### NVIDIA

Only runs when `nvidia_gpu_present: true` in that machine's `host_vars`, and
then only acts if **both** an NVIDIA device is really on the PCI bus **and**
`nvidia-smi` does not already report a working driver. So it is a no-op on an
already-working machine, and cannot fire on the laptop.

It uses `ubuntu-drivers install` — Ubuntu's own tool, which picks the right
driver for your card and kernel. Naming `nvidia-driver-580` instead would be
wrong by the next release.

If Secure Boot is on and a driver was *actually installed*, the checklist
prints the MOK enrollment steps. That part cannot be scripted: it is a
pre-boot firmware screen requiring physical presence.

### The keyboard layout

Two input sources — a custom English layout and Spanish — switched with
`Super+Space` (bound explicitly rather than trusted to default).

The custom layout is installed at `/usr/share/X11/xkb/symbols/custom`. That
name is **reserved**: `xkeyboard-config` lists `custom` in `evdev.xml` as "A
user-defined custom Layout" but deliberately ships no file for it. Since no
package owns that path, **package updates cannot overwrite it** — which is the
whole point, and why editing `symbols/us` was getting clobbered on every
update.

`roles/keyboard/files/custom` holds **your real mappings**, recovered by
diffing your hand-edited `symbols/us` against the pristine file from the
`xkb-data` package, and verified to compile with `xkbcomp`:

| AltGr + | gives | | AltGr + | gives |
|---|---|---|---|---|
| `a` `e` `i` `o` `u` | á é í ó ú | | `;` | ñ |
| `\` | ç | | `1` | ¡ |
| `/` | ¿ | | `3` | · |
| `` ` `` | º / ª | | `d` | € |
| `[` | grave dead key | | `'` | diaeresis dead key (ü) |

Shift+AltGr gives the capital: Á É Í Ó Ú Ñ Ç.

One correction to the original: your `symbols/us` edit never included
`level3(ralt_switch)`, so right-Alt only worked as AltGr because the Spanish
layout — loaded as your second input source — happened to provide it. The new
file declares it itself, so the layout works even on its own.

> After changing the layout you **must log out and back in**. GNOME compiles
> the keymap when your session starts; there is no supported way to force that
> from a script on Wayland.

---

## 9. Repo map

```
├── local.yml           # the playbook — start reading here
├── bootstrap.sh        # one-command entry for a fresh machine
├── Makefile            # shortcuts; `make` lists them
├── ansible.cfg         # so you need not pass the same flags every time
├── requirements.yml    # external collections, pinned to exact versions
├── inventory/hosts.yml # just localhost — see §4 for why
├── group_vars/all.yml  # >>> THE FILE YOU EDIT <<<
├── host_vars/          # per-machine overrides
├── roles/              # one directory per thing configured
└── vm/                 # disposable test VM harness
```

Every file is commented far more heavily than production Ansible normally is.
That is intentional — this repo doubles as the documentation for itself.

---

## 10. Troubleshooting

**"The keyboard layout did not change."** Log out and back in. If it is still
missing, check the layout compiles: `setxkbmap -print` won't help on Wayland —
instead confirm `gsettings get org.gnome.desktop.input-sources sources` lists
`custom`, and look for parse errors from the symbols file in `journalctl -b`.

**"The dconf tasks did nothing."** You almost certainly ran with `sudo`. See §6.

**"`community.general.snap` not found."** Run `make deps`. Note that
`ansible-pull` does **not** install `requirements.yml` — I verified this in its
source. The Ubuntu `ansible` package happens to bundle `community.general`, so
the documented bootstrap works, but `bootstrap.sh` installs it explicitly so
the repo also works with a bare `ansible-core`.

**"apt reports a duplicate source for Chrome."** You have both a legacy
`google-chrome.list` and the managed `.sources`. Delete the `.list`.

**A task reports `changed` every run.** That is a bug — file it. It usually
means a `command:` without `changed_when:`, or a package rewriting a file
Ansible also manages (exactly the Chrome problem `repo_add_once` solves).
