# PXE Bare-Metal-Imaging + Nested-Virt-Labor

> Status: PLAN (freigegeben). Kanonischer Ablageort für dieses Projekt. Schwester-Plan:
> `docs/lego-capabilities.md`.

## Kontext

Bare Metal provisionieren, ohne es anzufassen: in der UI ein aufgenommenes Disk-**Template** aktiv
markieren, ein Zielsystem per PXE in ein minimales Preinstallation Environment (PE) booten, das Template
per `partclone` auf die (meist größere) Zielplatte klonen und die Datenvolumes auf die Zielgröße wachsen
lassen — `/boot` bleibt fix, `/root`, `/var`, `/home` wachsen nach vom Operator gesetzten
**Prozent-Schiebereglern**. Ein einziger konsolidierter **`pxe-boot`-Container** hält alles, was das Labor
braucht (dnsmasq DHCP+TFTP, ein HTTP-Server für PE-squashfs + Images, und eine nested-virt QEMU mit
noVNC-Konsole), sodass die ganze Kette — inklusive dem *Bauen* eines Templates durch Installation eines
OS von einer ISO — auf `hal` gegen dessen zweite NIC `ens19` (192.0.2.130) läuft, ganz ohne echte Hardware.

Die Backend-Hälfte existiert bereits (siehe Anhang A): `services/imaging.py`, `offline_enroll.py`,
`api/images.py` (`/netboot/checkin` + `/netboot/progress` + Upload/Finish + `disk_images`/`restore_jobs`).
Es fehlen: der Serving-Stack, der PE-Client, das Multi-Volume-Wachstum, die UI und das QEMU-Labor.

### Entscheidungen (mit dem Operator festgelegt)
- **PE-Laden = RAM-PE (squashfs).** TFTP liefert Kernel + eine winzige initramfs; die initramfs zieht die
  PE-Wurzel als **squashfs (~250–400 MB) per HTTP** in den RAM (tmpfs/overlay) und pivot-rootet — **self-
  contained, keine Netzabhängigkeit während des Restores** (Ziel-RAM ~1 GB). Gewählt statt NFS-Root, damit
  ein Netz-Aussetzer mitten im Restore das Ziel nicht blockieren kann.
- **PE-Basis = Debian-minimal** (debootstrap) mit `agentic-mcpd` + `partclone`/`lvm2`/`e2fsprogs`/
  `xfsprogs`/`grub`/`curl` baked-in, gepackt mit `mksquashfs`.
- **Ein `pxe-boot`-Container** = dnsmasq (DHCP proxy|full + TFTP) + **HTTP-Server** (PE-squashfs + Images +
  `agent.deb`) + QEMU (nested) + noVNC. **Kein NFS** — RAM-PE plus der bestehende HTTP-Image-Abruf machen es
  überflüssig.
- **DHCP-Modus proxy|full konfigurierbar**; bindet `ens19`/192.0.2.130.
- **Alle Blöcke zusammen** bauen.

### Proxmox-Nested-Virt-Voraussetzung (die CPU-Frage, beantwortet)
`hal` ist eine Proxmox-VM, also braucht QEMU-im-Container KVM-Durchreichung:
1. **Proxmox-Host:** Nested am kvm-Modul aktivieren — Intel: `options kvm-intel nested=1` in
   `/etc/modprobe.d/kvm.conf` (AMD: `kvm-amd nested=1`), Modul neu laden oder rebooten; prüfen mit
   `cat /sys/module/kvm_intel/parameters/nested` → `Y`.
2. **Die `hal`-VM:** CPU-Typ auf **`host`** setzen (Passthrough — reicht `vmx`/`svm` an den Gast durch). Das
   ist die Antwort auf „welche CPU": **`host`**. (Alternative: benanntes Modell + `+vmx`/`+svm`-Flag.)

## Bootstrap-Workflow (abgestimmt mit dem Operator)

Nicht „boote und rate", sondern erst den Ziel-Host **planen + konfigurieren**, dann installieren:

1. **Geplanten Host anlegen** — ein **Agent-Row** im Zustand `enrollment_state='planned'` (noch nicht
   erreichbar, wie `record_offline_agent` schon einen anlegt, nur früher). Trägt: aktives **Template**,
   **Hostname**, **MAC** (die netbootende Maschine), **finale Netzwerk-Config** (statisch IP/GW/DNS oder
   DHCP — das des **Zielnetzes**, nicht des Rollout-/PXE-Netzes ens19).
2. **Disk-Geometrie (Partition-Manager, nur Größen, LVM-bewusst)** — aus dem Template-Manifest werden
   Partitionen **und die LVM-Struktur (VG/LVs)** gelesen und angezeigt. `esp`/`boot` gesperrt; `root`/`var`/
   `home` als Slider = `grow_policy` (Block 3, sizet die LVs). Raw-Layout → ein wachsendes Volume; LVM →
   per-LV-Slider. Struktur ist fix (partclone stellt genau die Template-Volumes wieder her).
3. **Rollen (bestehender Management-Tab)** — weil der geplante Host ein Agent ist, greift die vorhandene
   Rollen-/Paket-Zuweisung out-of-the-box; landet im Desired State.
4. **Armen** — erzeugt den `RestoreJob` (MAC → Template + grow_policy), verknüpft ihn mit dem geplanten
   Agent (`agent_id` schon beim Armen, nicht erst nach Enrol).
5. **PE bootet** — PXE → RAM-PE → `/netboot/checkin` → partclone-Restore + Multi-Volume-Grow → **chroot**:
   grub, Identität (Hostname), **finale Netzwerk-Config schreiben**, Agent installieren + registrieren →
   **einmaliger Reboot**. (Rollen werden hier NICHT angewendet.)
6. **Erster Boot am Zielnetz** — der Host kommt auf seiner finalen IP hoch, meldet sich (schon registriert),
   Downtime läuft ab, und der Agent **konvergiert die Rollen** dort — wo die Firewall/Repos stimmen.

**Neue Bausteine daraus (in die Blöcke unten eingearbeitet):** (a) `planned`-Agent-Zustand + Anlege-Flow;
(b) `RestoreJob.agent_id` beim Armen setzen (statt nur nach Enrol); (c) **finale Netzwerk-Config als
chroot-Step** in `offline_enroll`/`restore_steps` (schreibt /etc/systemd/network bzw. /etc/network/interfaces
im Ziel-Root); (d) die Provisioning-UI (Block 4) bindet Template + Host-Config + LVM-Slider + Rollen + Armen
zusammen; Rollen-Apply bleibt die **normale Reconcile-Schleife** nach dem Boot.

**Block 4d — Paketmanager-Proxy pro Distribution + Policy** (Voraussetzung für die post-Boot-Konvergenz am
Zielnetz). Schon vorhanden: `ConfigPolicy` (GPO-Präzedenz Host > OU > Gruppe) und das `dnf`-Template mit
`proxy`/`proxy_username`/`proxy_password`/`repo.proxy`. Lücken: (1) ein sauberes **apt-Proxy** (`Acquire::
http::Proxy`/`https::Proxy` + optional Auth) — eigenes `apt-proxy`-Template bzw. Feld in `apt.conf`; (2)
**SUSE/zypper** (`/etc/sysconfig/proxy`); (3) ein **Management-Tab-Panel „Paketmanager-Proxy"** je Host, das
die Distro-spezifischen Proxy-Werte editiert **und** per Aktion eine `ConfigPolicy` auf OU/Gruppe anlegt
(die Mechanik existiert, v. a. UI-Verdrahtung).

---

## Block 1 — Der `pxe-boot`-Container (`deploy/pxe/`)
Spiegelt das Sidecar-Muster von `deploy/poller/` (Dockerfile + `entrypoint.sh`, `context: .`, Proxy-ARGs,
statisches `agentic-mcpd` aus `deploy-artifacts/` kopiert).
- **Dockerfile** (`debian:trixie-slim`): `dnsmasq`, statischer HTTP-Server (`nginx`/busybox httpd),
  `squashfs-tools`, `qemu-system-x86`, `qemu-utils`, `websockify`, `novnc`, `curl`, `pxelinux`/`grub-efi`,
  `debootstrap`.
- **entrypoint.sh** (env-getrieben, first-boot-idempotent): templated `/etc/dnsmasq.conf` aus
  `DHCP_MODE(proxy|full)`, `PXE_INTERFACE=ens19`, `PXE_LISTEN_IP=192.0.2.130`, `DHCP_RANGE`, `DHCP_ROUTER`,
  `NEXT_SERVER`, `TFTP_ROOT`, `NETBOOT_SECRET` (Direktiven aus `configs/wizard_playbooks/install-dnsmasq.yml`
  /`dnsmasq.j2`); HTTP-Wurzel = PE-squashfs + Image-Store + `agent.deb`; startet `dnsmasq`, HTTP-Server,
  `websockify` und einen kleinen QEMU-Steuer-Listener; baut beim ersten Start das PE (`build-pe.sh`), falls
  `pe.squashfs` fehlt.
- **Compose:** neuer `pxe`-Service; **`network_mode: host`** (DHCP/TFTP brauchen L2 auf `ens19`),
  `devices: ["/dev/kvm"]`, Bind-Mounts: HTTP-Wurzel, Image-Store (geteiltes Volume), TFTP-Verzeichnis,
  **ISO-** und **Template-Verzeichnis**. Host-Spezifisches (ens19/IP/Secret/Ranges) in
  `docker-compose.override.yml`, Secret als `${BOSSMAN_NETBOOT_SECRET:-}`.

## Block 2 — Das PE (Debian-minimal, RAM-squashfs)
- **`deploy/pxe/build-pe.sh`**: `debootstrap` minimale Debian-Wurzel; installiert `agentic-mcpd`,
  `partclone`, `lvm2`, `e2fsprogs`, `xfsprogs`, `grub2`, `curl`; **oneshot-init-Unit** `pe-provision`, die
  beim Boot `netboot_secret=`/`bossman_url=` aus `/proc/cmdline` parst, MAC + `lsblk -b --json` +
  `sfdisk --json` sammelt, `POST /api/v1/netboot/checkin` (Header `X-Netboot-Secret`) aufruft und die
  gelieferten `steps` (partclone/lvm/grow/grub/offline-enrol) ausführt, gemeldet via
  `POST /netboot/progress/{job_id}`. Wurzel mit **`mksquashfs`** → `pe.squashfs` (~250–400 MB).
- **TFTP-Payload**: Kernel + **winzige initramfs** → `ip=dhcp`, `curl http://192.0.2.130/pe.squashfs` in
  den RAM, mounten (tmpfs/overlay), `pivot_root`. PXELINUX/GRUB hängt `netboot_secret=<secret>
  bossman_url=http://<bossman>:8123` an. Wiederverwendung: `/netboot/checkin` + `/netboot/progress`
  existieren (`api/images.py`); das PE ist der fehlende Client.

## Block 3 — Multi-Volume-Prozent-Wachstum (`services/imaging.py` + DB)
Heute wächst `plan_restore` nur das **letzte** Volume; künftig root/var/home prozentual, boot/esp/swap fix.
Einspeisepunkt: der eine `/checkin`-Aufruf bei **`api/images.py:320`**.
- **`classify_role`** (`imaging.py:213`): `"data"` in `"var"` (mp `/var`) und `"home"` (mp `/home`)
  aufspalten; `esp`/`boot`/`bios_boot`/`swap`/`root` bleiben.
- **`plan_restore`** (`imaging.py:377`): dritter Parameter `grow_policy` (`{"root":50,"var":30,"home":20}`).
  Volumes in **fix** (esp/boot/bios_boot/swap) und **wachsend** (root/var/home); `remaining` prozentual
  verteilen, je `_align_down`, mit den Per-Volume-Guards (xfs-Shrink, `GROWABLE`) in einer Schleife.
  `restore_steps` wächst schon jedes `grow=True`-Volume — dort keine Änderung.
- **`lvm_commands`** (`:568`): „letztes LV = `100%FREE`" → explizite Größen pro wachsendem LV;
  **`sfdisk_script`** (`:540`) analog bei rohen Partitionen.
- **DB** (`db/models.py`): `DiskImage.is_active` (partieller Unique-Index; `status`-CHECK bei :1627 ist die
  Vorlage) + `grow_policy: JSONB`; `RestoreJob` snapshottet `grow_policy` beim Armen. Alembic ab Head.
- **API**: `PATCH /images/{id}` (is_active + grow_policy, Summe ≈ 100); `/checkin` liest die grow_policy des
  aktiven Images → `plan_restore(layout, target, grow_policy)`.
- **Tests**: `test_imaging.py` (Multi-Volume, xfs-Guard, Summe) + `test_images_api.py` (active/policy).

## Block 4 — UI: `disk-templates` (`bossman-ui`)
**`disk-templates`** (NICHT `config-templates` — Jinja2-Feature, Namenskollision). Lazy-`loadComponent` +
`NAV_ITEMS`/`NAV_ICON`.
- **`features/disk-templates/`**: `DiskImage`s auflisten; **aktiv markieren** (Stern-Toggle → PATCH); ein
  **Grow-Policy-Editor** = drei Prozent-Slider (root/var/home), live auf Summe 100 constrained —
  `shared/config-dialog` (`sizeSlider` + `update()`-Hook; `host-storage.component.ts` als Beispiel); ein
  **Restore-Jobs**-Panel, das `/restore-jobs` pollt (`timer+switchMap` aus `check.service.ts`).
- **`core/services/images.service.ts`**: GET Images/Jobs, PATCH active/policy, POST Restore-Job.

## Block 5 — QEMU-Template-Install + noVNC
Bossman steuert QEMU im `pxe`-Container (Steuer-Socket / `docker exec` / kleine HTTP-Steuerung).
- **Template-Disk-Format = `qcow2` (thin).** Thin provisioniert + `qemu-img snapshot` (nach sauberer
  Installation snapshotten, zum Iterieren zurückrollen); für den Gast transparent (er sieht `/dev/vda`).
  Das **gespeicherte Golden-Template** ist davon unabhängig ein `partclone`+`zstd`-Stream pro Volume + ein
  Layout-Manifest (thin by construction) — kein Disk-Image-Format.
- **Template installieren**: `POST /api/v1/vm/install {image_id, iso}` startet
  `qemu-system-x86_64 -enable-kvm -cpu host -cdrom <iso-bind> -drive file=<template-bind>.qcow2,format=qcow2
  -vnc :N`; beim Herunterfahren wird die Template-Disk aufgenommen — `qemu-nbd --connect=/dev/nbd0
  <template>.qcow2` → `partclone.<fs> -c -s /dev/nbd0pN | zstd` (das bestehende `capture_pipeline` mit
  `device=/dev/nbd0pN`) → `PUT /images/{id}/files` → `/finish` → `DiskImage`. `GET/POST /vm/{id}` Status/Stop.
  (Der `pxe`-Container braucht dafür das `nbd`-Modul / `qemu-utils`.)
- **noVNC**: websockify-Brücke + chromeless UI-Seite `install-console/:id` mit noVNC-`RFB` (`@novnc/novnc`),
  Token in der WS-Query — spiegelt `host-console.component.ts` + `console-page.component.ts` (xterm → RFB).
- **PXE-Test-Ziel**: `POST /vm/pxe-test` bootet eine plattenlose QEMU-VM (`-boot n`, NIC im `ens19`-Segment)
  → PXE → PE → Restore des **aktiven** Templates end-to-end. Bind-Mounts: ISO- + Template-Verzeichnis.

## Block 6 — Verdrahtung, Secrets, Deploy
- Bossman-Env: `BOSSMAN_NETBOOT_SECRET` (aktiviert `/netboot/checkin`), `BOSSMAN_IMAGE_BASE_URL`, geteiltes
  **`bossman-images`-Volume** in `bossman` (`/etc/bossman/images`) und `pxe`; `agent.deb` an die Store-Wurzel.
- Agent neu bauen (`scripts/build-agent-deb.sh`) für aktuelles `agentic-mcpd` (inkl. `regex`-starmod).
- Deploy: `docker compose up -d --build`; Proxmox-Nested-Voraussetzung.

---

## Kritische Dateien
| Datei | Änderung |
|---|---|
| `deploy/pxe/Dockerfile`, `entrypoint.sh`, `build-pe.sh` | **neu** — Container + PE-Builder |
| `docker-compose.yml` / `docker-compose.override.yml` | **neu** `pxe`-Service + geteiltes Images-Volume |
| `bossman/bossman/services/imaging.py` | `classify_role` (+var/+home), `plan_restore(grow_policy)`, `lvm_commands`/`sfdisk_script` |
| `bossman/bossman/db/models.py` + alembic | `DiskImage.is_active`/`grow_policy`, `RestoreJob.grow_policy` |
| `bossman/bossman/api/images.py` | `PATCH /images/{id}`, grow_policy bei `/checkin:320`, `POST /vm/*` |
| `bossman-ui/.../features/disk-templates/*` + `core/services/images.service.ts` | **neu** |
| `bossman-ui/.../install-console` + `@novnc/novnc` | **neu** — noVNC-Seite |

Wiederverwenden: `deploy/poller/*`, `install-dnsmasq.yml`+`dnsmasq.j2`, `services/imaging.py`/
`offline_enroll.py`/`api/images.py`, `shared/config-dialog/*`, `host-console.component.ts`+`console-page`,
`check.service.ts`, `features/systems/*`.

## Verifikation (end-to-end, über das QEMU-Test-Ziel — keine Hardware)
1. `docker compose up -d --build`; `pxe` gesund; `dnsmasq` auf `ens19`; `pe.squashfs` per HTTP erreichbar.
2. Template aufnehmen (QEMU-Install ISO → Template-Disk → `DiskImage`), **aktiv** markieren, Grow-Slider
   setzen (z. B. root 50 / var 30 / home 20).
3. `POST /vm/pxe-test`: PXE → RAM-PE → `/netboot/checkin` → partclone-Restore + **Multi-Volume-Wachstum**
   (boot fix; root/var/home = Slider-%) + grub + offline-enrol → einmaliger Reboot; live über noVNC.
4. `RestoreJob` pending→running→done; VM erscheint **enrolled** mit Downtime, die abläuft; MAC frei.
5. `pytest` grün: `test_imaging.py` (Multi-Volume) + `test_images_api.py` (active/policy).
6. Wiederholen mit `DHCP_MODE=proxy` und `full`.

---

## Anhang A — Bestandsaufnahme (was existiert, was offen ist)

**Fertig + getestet:**
- **`services/imaging.py`** — reine Capture/Restore-Planung (~60 Unit-Tests). Kein Shrink (nur Used-Blocks
  via partclone, danach grow — ext4 *und* xfs); Größen in Bytes (`lsblk -b`). `plan_restore` wächst heute
  nur das letzte Volume; `restore_steps` (1–7): partition→lvm→restore→grow→mount→chroot→grub→identity→
  `configure_steps`. `GROWABLE={ext2,ext3,ext4,xfs}`, `TARGET_ROOT=/mnt/target`.
- **`offline_enroll.py`** — Agent-Install in ein noch nicht laufendes FS (chroot-Capability); `policy-rc.d`
  101, `systemctl --root=/ enable`, 45-min-Downtime.
- **`api/images.py`** — drei Auth-Wege (Bearer / `X-Netboot-Secret` / abgeleitetes `X-Image-Token`);
  `/images`, `/restore-jobs`, **`/netboot/checkin`** (plant den Restore, weil erst dort die Ziel-Plattengröße
  bekannt ist; mintet die Identität dort), `/netboot/progress`, Upload (`PUT …/files`, hasht beim Landen),
  `/finish`. Fällt zu, wenn `netboot_secret` leer.
- **DB**: `DiskImage` (`:1598`; name unique, `source_agent_id` SET NULL = golden, `status
  capturing|ready|failed`, `manifest`/`files` JSONB), `RestoreJob` (`:1631`; keyed by `target_mac`,
  `image_id` CASCADE, `status …`, `steps`/`log`, `agent_id` SET NULL, partial-unique auf aktive MAC).
  Migration `e5c1a8b46d92_disk_images.py`. Go: `targetRoot`-chroot (`internal/starmodules/realcaps.go`).

**Offen (Lücken, keine TODO-Marker):**
1. Netboot-Serving-Stack existiert nicht (kein TFTP/HTTP/dnsmasq) — größtes fehlendes Stück → **Block 1/2**.
2. Capture-Orchestrierung nicht verdrahtet (`capture_pipeline` hat null Aufrufer) → **Block 5** (QEMU-Capture).
3. Kein UI → **Block 4**.
4. Kein Capture/Restore-Timeout-Watchdog (stuck Job bleibt `running`, MAC gesperrt). ← offene
   „Capture-Timeout-Entscheidung"; als Härtung nachziehen.
5. `RestoreJob.agent_id`-Rückverknüpfung nach Enrol ungenutzt.
6. Cancel eines laufenden Jobs ist nur Intent (das Ziel hat den Plan schon).

---

## Umsetzungsstand (Stand: alle Blöcke code-fertig)

| Block | Inhalt | Status | Commit(s) |
|---|---|---|---|
| 1 | `pxe`-Container (dnsmasq DHCP+TFTP, nginx, squashfs, qemu, websockify, novnc) | fertig | `5678fa18` |
| 2 | RAM-PE (debootstrap + live-boot squashfs), `pe-init.sh` (checkin→steps→progress→reboot) | fertig | `5678fa18` |
| 3 | Multi-Volume-Prozent-Wachstum (`imaging.py`), `is_active`/`grow_policy`, Alembic | fertig | `896dfd08` |
| 4a | `planned`-Host-State + Arm-Link | fertig | `457c5b01` |
| 4b | `/checkin` liest `provision_network` → network-/offline-install-steps | fertig | `b44d38bb` |
| 4c | Provisioning-UI (`disk-templates`): Template/Aktiv/LVM-Slider/Host planen/Jobs | fertig | `7e04cb93` |
| 4d | Paketmanager-Proxy pro Distro (apt-proxy + suse-proxy Templates) | fertig | `cc86f0ef` |
| 5 | QEMU-Steuerung (`vm-control.sh`) + Bossman `/vm/*` (install/pxe-test/list/stop) | fertig | `9dbffeb0` |
| 5b | noVNC-Konsole (VNC-WS-Relay + `vm-console`-Seite + Lab-Panel) | fertig | `7e56e626` |
| 6 | Deploy-Verdrahtung (Compose/Dockerfile), Alembic geklärt | fertig | *dieser Commit* |

**Alembic:** kein Zwei-Head-Problem (das war ein Parser-Bug in einem Ad-hoc-Skript, das
`down_revision: Union[...] = '…'` nicht erkannte). Ein sauberer Verlauf, ein Head `e4b2c1d8f6a3`; die
zwei PXE-Migrationen sind gegen die Dev-DB angewendet. Deploy = schlichtes `alembic upgrade head`.

## Deploy-Runbook (Operator, auf `hal`)

1. **Nested-Virt am Proxmox-Host** (einmalig): Intel `options kvm-intel nested=1` in
   `/etc/modprobe.d/kvm.conf` (AMD: `kvm-amd nested=1`), Modul neu laden/rebooten, prüfen
   `cat /sys/module/kvm_intel/parameters/nested` → `Y`. Die `hal`-VM auf CPU-Typ **`host`** setzen.
2. **Bridge für den PXE-Test** (einmalig): `br-ens19` auf dem Host anlegen und `ens19` einsklaven
   (oder `PXE_VM_BRIDGE` auf eine vorhandene Bridge setzen).
3. **Agent neu bauen**, damit PE/Ziele das aktuelle `agentic-mcpd` (inkl. `regex`-starmod-Modul)
   bekommen: `scripts/build-agent-deb.sh` → legt `deploy-artifacts/agentic-mcpd` + `agent.deb` ab
   (die der pxe-Dockerfile hineinkopiert).
4. **Lab aktivieren** in `docker-compose.override.yml` (host-lokal, git-ignoriert):
   ```yaml
   services:
     bossman:
       environment:
         BOSSMAN_PXE_CONTAINER: agentic-mcp-pxe
         BOSSMAN_NETBOOT_SECRET: <secret>
         BOSSMAN_IMAGE_BASE_URL: http://192.0.2.130
     pxe:
       environment:
         BOSSMAN_NETBOOT_SECRET: <secret>   # gleiches Secret
   ```
5. **Hochfahren**: `docker compose --profile pxe up -d --build`. Der `migrate`-Service fährt
   `alembic upgrade head` konfliktfrei; der `pxe`-Container baut beim ersten Start das PE.
6. **End-to-End** (ohne echte Hardware): Template über QEMU-ISO-Install aufnehmen → aktiv markieren →
   Grow-Slider setzen → „PXE-Test starten" → über noVNC zusehen, wie das plattenlose Ziel per PXE das
   RAM-PE zieht, das aktive Template restauriert (boot fix, root/var/home = Slider-%), grubt,
   offline-enrolt und einmal rebootet; der `RestoreJob` läuft pending→running→done, das Ziel erscheint
   **enrolled**. Mit `DHCP_MODE=proxy` und `full` wiederholen.

**Verifiziert (ohne Hardware):** `vm-control.sh` `sh -n`; `vm_lab` 16 Unit-Tests (argv/Guards); Bossman-
Imports + die 5 `/vm`-Routen; `ng build` grün (noVNC 1.5, kein TLA); `docker compose (--profile pxe)
config` parst; Alembic-Migrationen angewendet. **Deploy-gebunden** bleibt nur, was `/dev/kvm` + die
ens19-Bridge braucht (Schritte 1–2, 5–6).
