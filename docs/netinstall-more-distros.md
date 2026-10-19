# Preparing network installs for SUSE, Arch and Alpine

Status: **prepared, not built.** Fedora, AlmaLinux, Debian and Ubuntu install through `deploy_vm(install=…)` and
the Install hosts wizard today (docs/kernel-tuning.md, "Four distributions through their own installers"). This
page collects what a driver for openSUSE/SLES, Arch Linux and Alpine needs, so the work can start from facts.
Everything under "to verify" has **not** been measured yet and must be checked against a real mirror and a real
VM before it is relied on.

## What a driver is

A driver is one class in `bossman/bossman/services/netinstall.py`, registered in `DRIVERS`. The rest of the path
(the VM created stopped, the per-MAC boot entry, the local mirror, DHCP bound to the checked address, the shared
`finish.sh`, `done` on the agent's first report) is the same for every distribution and does not change.

| Member | What it must give |
|---|---|
| `name`, `title`, `family` | the `install=` key, the label in the wizard, the OS family (`internal/osfamily`) |
| `config_name` | the file the installer reads unattended (kickstart, preseed, user-data, …) |
| `min_memory_mb`, `cpu_model` | measured minimums; each is a pre-flight check (see AlmaLinux's x86-64-v3, Ubuntu's 8 GB) |
| `default_packages` | the benchmark tools under this family's names, checked against the repositories |
| `resolve(c, release)` | the newest stable release from the mirror when none is named, and its kernel/initrd URLs |
| `fetch(rel)` | what the pxe container mirrors (`area` tftp or http) — once per release |
| `boot(rel, …)` | the pxelinux `kernel`/`initrd`/`append` for the MAC's entry |
| `render(rel, …)` | the unattended configuration: static network, proxy for the package repository only, root locked, agent port opened, the packages, and a last step that runs `finish.sh` |
| `known_packages(c, rel, letters)` | the package names the release offers, for the "packages available" check |

Two parts outside the driver also need a case per new family:
- `finish.sh` (`render_finish`) installs the agent package for the family (`.deb`, `.rpm` today).
- `services/agent_update.py` refuses an unknown family; it needs the package for the new one.

## openSUSE Leap 16 / SLES 16 (family `suse`)

- **Installer:** Leap 16 and SLES 16 replaced YaST with the **Agama** installer. Unattended installation reads an
  Agama profile (JSON or Jsonnet); AutoYaST profiles are accepted through a compatibility layer. *To verify:* the
  boot parameter that names the profile URL (`inst.auto=`), how Agama takes a static network and a proxy, and
  whether its installation repository can be mirrored like Fedora's stage2.
- **Kernel/initrd:** the repository's `boot/x86_64/loader/` directory (`linux`, `initrd`). *To verify* for Leap 16
  and Tumbleweed.
- **Agent package:** `.rpm` works for SUSE today (`update_agent` already sends the .rpm to the suse family);
  `finish.sh` needs `zypper --non-interactive install` instead of dnf for the dependencies.
- **Tunables:** `kernel_cmdline` knows GRUB via `grub2-mkconfig`; SUSE's systemd-boot via `sdbootutil` is
  `unsupported` today.

## Arch Linux (family `arch`)

- **Installer:** Arch has no unattended installer of its own. The archiso netboot image boots into a live system,
  and `archinstall` installs from a JSON configuration (`--config`, `--creds`, `--silent`). The driver would boot
  archiso over HTTP and start `archinstall` with the rendered configuration; the "installer" is then a script.
  *To verify:* the archiso netboot parameters (`archiso_http_srv=`, `ip=`) and how to run a script at the end of
  the live boot without manual input.
- **Release:** rolling. `resolve` names the archiso build date instead of a version.
- **Agent package:** nfpm can build Arch packages (`.pkg.tar.zst`). `build-agent-deb.sh` would add a third
  `nfpm package -p archlinux`, and `agent_update` would send it to the `arch` family.
- **scx:** Arch packages scx (`scx-scheds`); whether it loads into the current kernel is *to verify* — the bundled
  build (`/usr/lib/yoloman/scx`, glibc ≤ 2.39) is the fallback either way.

## Alpine Linux (family `alpine`)

- **Installer:** Alpine's netboot files (`vmlinuz-lts`, `initramfs-lts`, `modloop-lts`) boot a RAM system;
  unattended installation is `setup-alpine -f <answerfile>`, started from an overlay (`apkovl=` URL) whose
  `local.d` script runs it. *To verify:* the boot parameters (`alpine_repo=`, `modloop=`, `apkovl=`, `ip=`) for the
  current release and that `setup-alpine -f` with `DISKOPTS` installs to disk without a prompt.
- **The blocker is the agent, not the installer.** Alpine uses **musl**, and the agent is built with CGO against
  glibc (PAM). It needs a CGO-free static build (the `!cgo` path already authenticates through `unix_chkpwd`,
  `internal/authz/chkpwd.go`) packaged as `.apk` (nfpm supports `-p apk`), and an OpenRC service instead of the
  systemd unit.
- **Tunables:** OpenRC is handled by `sched_ext` (its init script) and `cpu_governor` (`local.d`);
  `systemd_resource` is `unsupported` there. The bundled scx binaries are linked against glibc and **will not run
  on musl**; Alpine would need its own scx build or the `scx` package from its repositories (*to verify*).

## Order of work, when it starts

1. openSUSE — closest to what exists (rpm, systemd, GRUB); the open question is Agama's unattended interface.
2. Arch — the agent package is one nfpm call; the installer is a script around `archinstall`.
3. Alpine — first the CGO-free, OpenRC-capable agent; the installer after that.

Each driver is done when the same proof as for the four existing ones passes: a VM installed through `deploy_vm`
from a dry run whose checks all pass, the agent's first report, `kernel_caps`, the benchmark profiles, and one
tunable applied and rolled back.
