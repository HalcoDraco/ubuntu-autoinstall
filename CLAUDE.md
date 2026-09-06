# CLAUDE.md — conventions for this repo

Read this before changing anything. These rules exist because breaking them is
how the repo rots on the next Ubuntu release.

## What this repo is

Ansible automation that converges a fresh Ubuntu **desktop** to Pablo's
preferred state. Must run unchanged on **Ubuntu 22.04, 24.04 and 26.04**.
Runs on a desktop (NVIDIA GPU) and a laptop (no GPU). Re-run periodically to
converge, not just after a reinstall.

The user was new to Ansible when this was written. **Comment generously and
explain each new concept the first time it appears.** The repo doubles as its
own documentation. When making a design choice with real alternatives, say
briefly why in a comment — that is an explicit requirement, not a nicety.

## Hard constraints

1. **Never hardcode a release codename.** Use `{{ ansible_distribution_release }}`.
2. **Never hardcode a versioned package name** (`openjdk-25-jdk` will rot).
3. **Prefer official upstream apt repos. Never PPAs** — they break across upgrades.
4. **Guard release-specific work** with
   `when: ansible_distribution_version is version('26.04', '>=')`.
5. **No X11 tools, ever.** No `setxkbmap`, no `xkbcomp`, no `xdotool`. 26.04 is
   Wayland-only and this machine is already on Wayland. Desktop config goes
   through **gsettings/dconf** exclusively.
6. **Write apt repo files with `template`, not with a repository module.**
   `apt_repository` writes the deprecated one-line format APT 3 warns about;
   `deb822_repository` needs ansible-core 2.15+ and **does not exist on 22.04**
   (which ships ansible 2.10). A template produces the modern deb822 `.sources`
   format on every version. Do not "modernise" this back to a module.
6b. **Use only Ansible features present in 2.10.** That is the floor set by
   22.04. Check before using anything newer.
7. **Always access facts as `ansible_facts['name']`, never as the bare
   `ansible_name` variable.** Ubuntu 26.04 ships ansible-core 2.20, which
   deprecates `INJECT_FACTS_AS_VARS`; the top-level `ansible_distribution`
   style variables are removed in core 2.24. The `ansible_facts` dict form
   works all the way back to 2.10, so it is both backward and forward safe.
   This was caught by an actual deprecation warning on a 26.04 test run.
8. **Do not touch Firefox.** Not installing, not removing, not configuring.
   The user changed their mind on this; leave it alone entirely.
9. **Ubuntu only.** Distro-agnosticism is explicitly *not* wanted — but keep
   package installs isolated in roles so the package layer could be swapped
   without a rewrite.

## Idempotency

Every task must be a no-op when the system is already correct. A task that
reports `changed` on a second run is a bug.

- Use a **module**, not `shell:`/`command:`, whenever one exists.
- When `command:` is genuinely unavoidable, it needs `changed_when:` and
  usually `creates:`, `failed_when:` and `check_mode: false`. See
  `roles/manual_steps/tasks/main.yml` for the canonical example with all three
  and a comment explaining why each is there.
- Watch for packages that rewrite files Ansible manages. Chrome does this; the
  fix is `repo_add_once="false"` in `/etc/default/google-chrome`. Without it
  the role reports `changed` forever.

## The `become` rule

`local.yml` sets `become: false` play-wide; tasks opt into root individually.

**Never make the play `become: true`.** dconf/gsettings tasks must run as the
invoking user with their session D-Bus. Root writes root's settings: no error,
no effect. `become: false` cannot climb back down from root, so the playbook
must be invoked as the user with `-K`, never under `sudo`.

## Structure

- **Role vs list entry:** an app gets a role only if it needs *logic* — a
  third-party repo, a signing key, group membership, a config file. One package
  name from Ubuntu's repos goes in `group_vars/all.yml` (VLC). One snap name
  goes there too (Spotify). Apply this test consistently.
- **Adding an app must be a one-line edit** to `group_vars/all.yml`, never a
  code change.
- **Per-machine variance via `host_vars/`**, never a forked playbook.
- **Every role carries a tag** matching its name, so `--tags docker` works.
- **Pin every external dependency** in `requirements.yml` to an exact version.
- `roles/packages/` has **no `defaults/main.yml` on purpose** — those lists are
  global user config belonging in `group_vars/all.yml`, and declaring them as
  role defaults would both duplicate the source of truth and force
  ansible-lint's role-prefix rule to rename them into something uglier.

## Inventory design (non-obvious — do not "fix" it)

`inventory/hosts.yml` contains **only `localhost`**, and `local.yml` loads
`host_vars/<hostname>.yml` itself via `first_found` with a `default.yml`
fallback. Reasons, from reading `ansible/cli/pull.py`:

1. `ansible-pull` always limits to `localhost,<fqdn>,127.0.0.1`. Listing real
   hostnames alongside `localhost` makes the whole playbook run **twice**.
2. A fresh machine's hostname is whatever was typed into the installer. If it
   is not in the inventory, `ansible-pull` matches nothing and **silently does
   nothing**.

Do not replace this with conventional inventory-based `host_vars` loading.

## Validation

```bash
make lint      # ansible-lint, production profile — must stay clean
make syntax    # parse check
make check     # --check --diff, read-only
```

`.venv/` holds a modern `ansible-lint` (Ubuntu's is 6.17, years behind).
Runtime uses the system Ansible that `bootstrap.sh` installs.

## Safety rules when working on this machine

- **`sudo` requires a password here** and cannot be run non-interactively. Give
  the user the exact command to paste rather than attempting it.
- **Do not run privileged tasks against this machine without asking.** It is the
  daily driver, and it is already fully configured — it is *not* a test target.
- Test in the VM (`make vm-*`), never on the host.
- Before anything that installs drivers, writes under `/usr/share`, or changes
  group membership: show what it will do and wait for confirmation.

## Machine facts (as of 2026-09-06)

- `Niaura-linux` — desktop, Ubuntu 24.04.4, GNOME 46, **Wayland**, RTX 2060 with
  driver 595.84 (DKMS, 3 kernels), **Secure Boot enabled**, Docker 29.7.2, user
  already in `docker` group. Already fully configured — expect all-`ok` runs.
- `/dev/kvm` is accessible via a systemd-logind ACL (`user:pablo:rw-`), so the
  VM harness needs **no group membership and no logout**.
- The `custom` XKB layout name is confirmed reserved and unclaimed here:
  declared in `evdev.xml`, with no `symbols/custom` file shipped.

## Current status

All roles implemented: `base`, `packages`, `chrome`, `docker`, `nvidia`,
`nvidia_container`, `mise`, `keyboard`, `manual_steps`.

Gotchas discovered the hard way, do not regress these:
- Inside a `>-` folded YAML scalar, `#` is literal text, NOT a comment.
  Putting one in an expression appends a string to a list and fails at render.
- `mise install` always exits 0, so `changed_when` must be derived by diffing
  requested tools against `mise ls --installed --json`, never from output text.
- `ansible.builtin.user` needs `append: true` when adding a supplementary
  group. Omitting it REPLACES all groups and would strip `sudo`.
- Docker publishes per-codename repos and can lag a new Ubuntu release, so the
  role HEAD-checks the repo before writing a source file.
- Any apt install backed by a repo THIS PLAYBOOK adds must carry
  `when: not (ansible_check_mode and <repo>.changed)`, and so must everything
  downstream of it (services, groups). In --check the repo file is never
  written and the cache never refreshed, so the package is genuinely absent
  and `make check` fails on a fresh machine. This bit us three times: chrome,
  mise, then docker's service+group tasks.
- Docker Engine alone CANNOT use the GPU. nvidia_container installs the NVIDIA
  Container Toolkit; without it `docker run --gpus all` fails. Check
  daemon.json before running nvidia-ctk -- it always exits 0 and reconfiguring
  restarts Docker, killing running containers.

The keyboard layout now contains the user's REAL 14 key mappings, recovered by
diffing their hand-edited `/usr/share/X11/xkb/symbols/us` against the pristine
file from the `xkb-data` package, and verified to compile with `xkbcomp`.

For `docker`, the plan is **hand-rolled rather than `geerlingguy.docker`** —
that role carries multi-distro branching we do not need and Ubuntu-version
logic likely to break on 26.04. Five explicit tasks beat a dependency to audit.
