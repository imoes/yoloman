# Disk & Partition Management — Umsetzungsplan (gparted-komfortabel)

> Ziel: eine Festplatten-/Partitionsverwaltung pro Host, **so komfortabel wie
> gparted** — visueller Disk-Balken, Operationen staged in eine Warteschlange,
> ein **Apply**, das alles der Reihe nach ausführt. Über den Bossman-Agent statt
> lokal. gparted-Quelle liegt unter `../gparted` (git clone).

## 1. Was gparted „komfortabel" macht (das Modell zum Spiegeln)

Aus `../gparted/src`:
- **Device + Partition + PartitionVector** (`Device.cc`, `Partition.cc`) — eine
  Platte, ihre Partitionen als geordnete Liste inkl. **FREE-Segmenten**.
- **FileSystem-Capability-Matrix** (`FileSystem.cc`, `SupportedFileSystems.cc`,
  per-FS `ext2.cc`, `ntfs.cc`, `xfs`, `btrfs`, `fat16/32`, `exfat`, `f2fs`,
  `linux_swap.cc`, `luks.cc`, `lvm2_pv.cc`) — pro Dateisystem: kann create /
  grow / shrink / move / label / check, und mit welchem Tool. **Das** graut im
  UI unmögliche Aktionen aus (z. B. „shrink" wenn das FS es nicht kann).
- **Operation-Queue** — der Kern des Komforts: `Operation.cc` + konkrete Ops
  `OperationCreate/Delete/Format/ResizeMove/Copy/Check/LabelFileSystem/
  NamePartition/ChangeUUID` + `HBoxOperations.cc` (die Liste „pending
  operations"). Man staged Änderungen **ohne** die Platte anzufassen und macht
  sie einzeln rückgängig.
- **GParted_Core.cc** — scannt Geräte (libparted + `blkid`/`lsblk`/`/proc/mounts`,
  s. `FS_Info.cc`, `Mount_Info.cc`, `Proc_Partitions_Info.cc`) und **wendet die
  Queue an** (parted für die Partitionstabelle, `mkfs.*`/`resize2fs`/`ntfsresize`
  … für FS), mit Fortschritt (`Dialog_Progress.cc`, `OperationDetail.cc`).
- **Win_GParted.cc** + **DrawingAreaVisualDisk.cc** — Hauptfenster + der visuelle
  Balken; Dialoge je Op (`Dialog_Partition_New/Resize_Move/Info`, …).

Kurz: **Scan → visuell zeigen → Ops in eine Queue staged → ein Apply, geordnet,
mit Fortschritt → Safety (unmount/Warnungen)**. Genau das bauen wir nach.

## 2. Bossman heute

- **READ (zu grob):** `internal/inventory/inventory.go` `collectDisks()` liefert nur
  Platten (name/size/model/rotational) aus `/sys/block` — **keine** Partitionen,
  FS, Mountpoints oder Free-Space.
- **EXECUTE (teils da):** eingebettete Ansible-Module
  `internal/starmodules/embedded/modules/community.general/{filesystem,lvg,lvol}.yaml`
  (mkfs/FS-resize, LVM). **Fehlt:** `parted`/`mount` (Partitionstabelle,
  fstab/mount) — bzw. ein dediziertes Disk-Apply-Modul. Präzedenz: PXE-
  `deploy/pxe/provision-modules/yoloman/disk_partition.star`.
- **Drumherum:** Imaging/`RestoreJob`, `/disk-templates` (Disk-Images), qemu-nbd —
  eine *andere* Domäne (Images schreiben), nicht die Live-Partitionsbearbeitung.
- **Bausteine, die wir wiederverwenden:** die Modul-Bibliothek (Regel
  „use-module-library" — nicht als Shell nachbauen), das Resource-Protokoll
  (plan/apply/**generations/rollback**), der Observed-State-Cache (poller-
  refreshed), `run-module`.

**Lücke:** partitionsgenaues READ + Partitions-Ops + die Queue/Apply-UX.

## 3. Datenmodell

```
DiskLayout (pro Host, gecacht wie observed_state)
  devices: [ Device{
     name (/dev/sda), size_bytes, table (gpt|msdos|none), model, rotational,
     partitions: [ Partition{ num, start_s, end_s, size_bytes, kind(primary|extended|logical|free),
                    fstype, label, uuid, flags[], mountpoint, used_bytes, avail_bytes,
                    busy(mounted/held) } ],
     free: [ {start_s, size_bytes} ]  // aus `parted print free`
  } ]

DiskPlan (die gparted-Queue, pro Host, staged)
  ops: [ Operation ]  # geordnet
    OpCreate   {device, start_s, size_s, kind, fstype?, label?}
    OpDelete   {device, num}
    OpFormat   {device, num, fstype, label?}          # mkfs
    OpResizeMove {device, num, new_start_s, new_size_s} # FS+Partition, richtige Reihenfolge
    OpLabel/OpFlags/OpMount {device, num, mountpoint, fstab?}
  → validate() gegen die FS-Capability-Matrix + Busy/Safety
  → compile() → geordnete Agent-Modul-Schritte
```

FS-Capability-Matrix (klein, gespiegelt aus `SupportedFileSystems.cc`): pro fstype
`{create, grow, shrink, move, label, tool}` — treibt Ausgrauen im UI **und** die
Apply-Reihenfolge (shrink FS **vor** Partition verkleinern; grow FS **nach**
Partition vergrößern — genau wie gparted).

## 4. READ — partitionsgenaues Layout

Ein Discover-Schritt lässt den Agent (über das generische `command`-Modul, kein
neues Recht):
- `lsblk -b -J -O` → Namen, Typ, Größe, fstype, mountpoint, fsused/fsavail, uuid, label, part-flags;
- `parted -m -s <dev> unit s print free` → Partitionstabelle-Typ + **FREE-Segmente** + start/end in Sektoren.
Zusammengeführt zum `DiskLayout` oben. **Neuer Endpoint** `GET /api/v1/agents/{id}/disks`
(+ `?refresh=true`), gecacht analog `AgentObservedState` (poller-refreshed).
Read-only, keine Rechte über das hinaus, was der Agent eh liest.

## 5. EXECUTE — Queue → Agent-Module (geordnet)

`compile(DiskPlan)` → geordnete Schritte, jede Op auf vorhandene/kleine Module:
| Op | Modul |
|---|---|
| Create/Delete/ResizeMove (Tabelle) | **`parted`** (neu: Ansible-community.general-Port, oder `sfdisk`-Wrapper) |
| Format (mkfs) / FS-grow/shrink | **`filesystem`** (vorhanden) |
| Mount + fstab | **`mount`** (neu) |
| LVM (PV/VG/LV) | **`lvg`/`lvol`** (vorhanden) |
| LUKS | (später) |

Reihenfolge wie gparted: shrink-FS → shrink/move-Partition → grow-Partition →
grow-FS → mkfs → mount. Apply läuft als **eine geordnete Sequenz** (Runbook-artig)
mit Fortschritt je Op (`OperationDetail`-Analog).

**Preview/Dry-run:** parted hat keinen echten Dry-run — Preview = die berechnete,
geordnete Kommandoliste **+ der resultierende Layout-Diff** (vorher/nachher-Balken).
**Rollback:** vor Apply Partitionstabelle sichern (`sfdisk -d <dev>` Dump als
Generation); bei Fehler in einer Tabellen-Op zurückschreiben (`sfdisk <dev> < dump`).
FS-/Daten-Ops sind nicht reversibel → dafür klare Warnung + Bestätigung, kein Auto-Rollback.

## 6. SAFETY (nicht verhandelbar)

- **Busy-Guard:** keine Änderung an einer gemounteten Partition ohne vorheriges
  Unmount; kein Anfassen der Root-/Boot-Platte außer mit explizitem „Ich weiß was
  ich tue"-Opt-in.
- **Destruktiv-Bestätigung** je Daten-verlierender Op + Gesamt-Diff vor Apply.
- **Tabellen-Backup** (`sfdisk -d`) als Rollback-Punkt (Generation).
- **Tool-Check:** Apply prüft vorab, dass die nötigen Tools am Host da sind
  (`parted`, `e2fsprogs`, `xfsprogs`, `ntfs-3g`, …) — sonst klare Meldung statt
  halbem Zustand.
- **Nur READ ist default sichtbar**; die mutierende Seite hinter demselben
  Approval/Guardrail-Gate wie andere Änderungen (Change-Proposal/YOLO).

## 7. UI — der gparted-Komfort

Neuer **„Disks"-Tab** auf der Host-Seite:
- **Visueller Disk-Balken** je Gerät (Analog `DrawingAreaVisualDisk`): Partitionen
  farbcodiert nach fstype, FREE-Segmente sichtbar, Belegung (used/avail) als Füllung.
- **Partitionstabelle** darunter (num, fstype, label, size, used, mount, flags).
- **Rechtsklick/Buttons** → New / Delete / Resize-Move / Format / Label / Flags /
  Mount — unmögliche Aktionen ausgegraut (Capability-Matrix).
- **Pending-Operations-Liste** (Analog `HBoxOperations`): staged Ops, einzeln
  entfernbar, mit Vorher/Nachher-Diff.
- **Apply** (mit Fortschritt je Op) + **Undo** (Queue leeren vor Apply).
Damit ist der Bedien-Flow 1:1 der von gparted — nur remote über den Agent.

## 8. Phasen (safety-first)

1. **READ + Visualisierung (read-only).** disk_layout-Discover + `GET /agents/{id}/disks`
   + der „Disks"-Tab mit Balken + Tabelle + Free-Space. Kein Mutieren. Sofort nützlich,
   null Risiko.
2. **Sichere Ops + Apply.** Format(mkfs) einer *unmounteten* Partition, FS-grow,
   Label, Mount/fstab — über `filesystem`/`mount`. Tabellen-Backup + Preview-Diff +
   Apply mit Fortschritt. Busy-Guard.
3. **Partition create/delete/resize-move.** Der destruktive Kern über `parted`/`sfdisk`
   (neues Modul) — starke Safety + Rollback via sfdisk-Dump. Grow/shrink-Reihenfolge.
4. **LVM/LUKS-Komfort.** PV/VG/LV über `lvg`/`lvol`; LUKS-Container.

## 8a. Umgesetzt (Stand)

- **READ/Visualisierung** — `GET /agents/{id}/disks` (`services/disk_layout.py`) +
  „Disks"-Tab mit Balken, Tabelle, Free-Space, LVM.
- **Op-Engine** (`services/disk_ops.py`): `compile`→ geordnete Host-Kommandos,
  `safety_check`→ Guardrails, `apply`→ mit Tabellen-Backup (sfdisk -d) +
  Tool-Preflight (best-effort Install). Ops: mklabel, mkpart, mkfs, label, mount,
  umount, delete, **resize (grow & shrink)**, lvextend (online grow), **lvreduce
  (LVM shrink; fs shrunk first via --resizefs, needs unmount)**, and **ZFS**
  (zfs_create/set/snapshot/rollback/destroy + zpool_create/add/destroy).
- **ZFS** — read via `zpool list` + `zfs list -t all` (pools + datasets with
  used/avail/quota/refquota/reservation/mountpoint), degrades to `available:false`
  without a loadable module. Sizing is a **property** (`zfs set quota|refquota|
  reservation|refreservation`), online & non-destructive — not geometry. Destroy/
  rollback are refused when the pool/dataset (or a child) holds a critical mount;
  `zpool create/add` guard each raw vdev (loop-only unless allow_nonloop, protected
  + busy). **Live-verified on test-deployment /dev/sdb**: zpool_create → zfs_create →
  zfs_set refquota=4G (resize) → snapshot → rollback → read-back via _read_zfs → destroy
  → wipefs, all ok.
  - **Agent constraint (important):** the agent runs sandboxed (`ProtectKernelModules=true`
    + a private mount namespace), so it cannot load the ZFS kernel module and cannot see
    host-side module installs. The module must be present + loaded on the HOST (install
    zfsutils-linux + zfs-dkms + matching linux-headers, then modprobe / `/etc/modules-load.d/
    zfs.conf`). Once loaded, the agent's zpool/zfs commands work (they only ioctl /dev/zfs).
    disk_ops.apply preflights `/dev/zfs` and returns a clear "load it on the host" error if
    the module is missing.
- **resize** — verkleinert/vergrößert eine *unmountete* ext-Partition **samt FS** in
  der datensicheren gparted-Reihenfolge: Shrink `e2fsck → resize2fs <größe> →
  parted resizepart`; Grow `parted resizepart → resize2fs` (füllt). ext2/3/4 only
  (xfs/andere können nicht shrinken); Ziel muss unmountet sein (Busy-Guard via
  `busy_target`). parted fragt beim Shrink trotz `-s` nach → Schritt läuft über
  `sh -c … ---pretend-input-tty … Yes`. **Real verifiziert** auf test-deployment
  (`/dev/sdb1`: 32768→8192 MiB shrink, 8192→20480 MiB grow, FS intakt).
- **Safety** — loop-only außer `allow_nonloop`; Platten mit gemountetem FS sind hart
  geschützt (System-/Root-Platte); kritische Mounts nie unmountbar; lvextend nur
  online-GROW.

## 8f. LUKS (Passphrase bleibt im Vault)

Ops: `luks_format` (verschlüsseln + öffnen), `luks_open` (entsperren), `luks_close`.
Die Passphrase ist das eigentliche Problem, deshalb bewusst so gelöst:
- Die Op trägt ein **Vault-Handle** (`secret_ref`), nie Klartext. Wird doch Klartext
  übergeben, wird die Op **verweigert** — und der Wert nicht in der Fehlermeldung
  zurückgespiegelt.
- `compile()`-Ausgabe = genau das, was **Preview** zeigt → enthält nur das Handle.
  Ein Plan kann geprüft, gespeichert und geloggt werden, ohne etwas zu verraten.
- Erst `apply()` entschlüsselt und injiziert den Wert in einen **`copy`**-Modulaufruf
  (Step-Felder `secret_param`/`secret_ref`). Damit reist die Passphrase im
  **mTLS-Body**, nicht in `argv` (eine Kommandozeile steht in `ps` und im Audit-Log).
- Key-File auf **`/run` (tmpfs)**, `shred` in **derselben Shell** wie `cryptsetup` —
  ein fehlgeschlagenes Format kann sie nicht liegen lassen.
- UI: Toolbar zeigt kontextabhängig **Unlock/Lock** (bei crypto_LUKS bzw. offenem
  Mapper) oder **Encrypt** (bei einer freien, unmounteten Partition). Passphrase-Wahl
  **generieren / eingeben / bestehendes Handle**; „generieren" zeigt das Passwort
  **einmal** an (ein LUKS-Passwort, das niemand kennt, macht die Daten unbrauchbar).
  Das Klartext-Passwort geht per `POST /api/v1/vault/encrypt` **einmal** zum Server
  und nur das zurückgegebene Handle landet in der Op.

**Live verifiziert** auf `/dev/sdb2`: LUKS2/aes-xts-plain64 angelegt, ext4 im Mapper,
`luks_close` → inactive, `luks_open` mit demselben Handle → wieder entsperrt und das
ext4 intakt, keine `/run/bm-luks-*` übrig. In der UI geprüft, dass der Klartext
nirgends im DOM erscheint (nur „passphrase from the vault").

## 8e. Partition verschieben (echter Move, mit Daten)

Ein Move sind **dieselben Bytes an einem neuen Offset** — also eine Blockkopie, wie
gparted sie macht (`../gparted/src/CopyBlocks.cc`). Zwei Dinge machen es heikel, und
beide sind gelöst:

1. **Richtung.** Liegt das Ziel *hinter* der Quelle, überlappen die Bereiche; vorwärts
   zu kopieren würde ungelesene Bytes überschreiben. gparted negiert dafür seine
   Blockgröße und beginnt am Ende (`CopyBlocks.cc:106-112`) — wir kopieren aus
   demselben Grund **rückwärts**. `dd` kann das nicht (nur vorwärts).
2. **Laufzeit.** Der Agent bindet Kindprozesse an den HTTP-Request
   (`exec.CommandContext`), also stirbt ein Mehr-GB-`dd` beim Client-Timeout —
   mitten in der Kopie. Deshalb ist der Kopierer **kein Kommando**, sondern ein
   **natives Go-Modul** im Agent: `internal/modules/disk_move.go`,
   `action=start` → `job_id`, `status` → `{state, done_bytes, percent}`, `cancel`.
   JSON rein, JSON raus. Jeder Poll ist ein eigener kurzer Request.

Die Op-Engine kennt dafür zwei zusätzliche Step-Arten: `{tool, params}` (Modulaufruf,
gibt Werte wie `job_id` an Folge-Steps weiter) und `{poll}` (wartet bis `state !=
running`, Backoff 0,5 s → 10 s, Abbruch nach 6 h). Die `movepart`-Op ist damit:
**Kopie starten → auf den Job warten → erst dann die Tabelle umbiegen**
(`parted rm` + `mkpart` am neuen Offset). Reihenfolge bewusst so: während die Kopie
läuft, beschreibt die alte Tabelle noch, wo die Daten liegen.

**Safety:** Zielbereich darf keine andere Partition überlappen (Prüfung gegen die
Sektorbereiche des Layouts), Partition muss unmounted sein. Tabellen-Backup wie immer
per `sfdisk -d`. Fs-agnostisch, solange die Länge gleich bleibt (fs-Resize ist eine
eigene Operation).

**Live verifiziert** auf test-deployment `/dev/sdb`: 6-GiB-ext4-Partition mit 300 MiB
Zufallsdaten, Verschiebung um die halbe Größe nach rechts (Überlappung 6.291.456
Sektoren, `backwards=True`), 6.442.450.944 Bytes kopiert → Prüfsumme der Partition
**und** der Nutzdatei unverändert, `e2fsck` clean.

## 8d. Fehlende Host-Werkzeuge

Zwei Wege, bewusst unterschiedlich:
- **Apply installiert automatisch** (`disk_ops._ensure_tools`-Preflight): was der Plan
  braucht, wird per apt/dnf/yum/zypper/apk nachgezogen und als `tools_installed`
  gemeldet — dort hat der Nutzer der Änderung ohnehin zugestimmt.
- **Der Scan meldet nur** (`disk_layout._read_tools` → `tools:{missing,packages}`):
  Pakete zu installieren, nur weil jemand eine read-only Ansicht öffnet, wäre eine
  überraschende Nebenwirkung. Das Panel zeigt stattdessen eine Hinweiszeile
  („Missing on this host: parted, …") mit **Install**-Button →
  `POST /agents/{id}/disks/tools` (`disk_ops.install_tools`, nimmt nur Binaries an,
  die der Editor wirklich fährt).
- **Eine Paket-Map** (`disk_ops._PKG_FOR_BIN`) für beide Wege. Vorher hatte der Scan
  eine eigene Liste — `cryptsetup` wurde als fehlend gemeldet, hatte aber kein
  Mapping und wurde beim Installieren stillschweigend verworfen. Live gefunden und
  behoben.

## 8c. Gewachsene VM-Platte (on the fly, ohne Reboot)

Vergrößert der Hypervisor eine virtuelle Platte, muss das **im Betrieb** ankommen:
- **Refresh-Button** im Panel löst vor jedem Scan einen Hardware-Rescan aus
  (`disk_layout._rescan_devices`): `echo 1 > /sys/class/block/*/device/rescan`
  (neue Kapazität), `echo '- - -' > /sys/class/scsi_host/host*/scan` (neu
  angehängte Platten), danach `partprobe`. Alles daten-neutral.
- **Erkennung:** `tail_free_bytes` = unallokierter Raum **hinter** der letzten
  Partition; `gpt_needs_fix`, wenn parted meldet, dass der GPT-Backup-Header noch
  am alten Ende liegt.
- **Ein Klick („Use the new space")** reiht die passende Kette ein:
  `gptfix` (`sgdisk -e`, nur bei GPT) → `growpart` (`parted resizepart <n> 100%`)
  → bei LVM **`pvresize`** → `lvextend --resizefs` (online) ; bei einer reinen
  ext-Partition stattdessen `resize` (grow) → `resize2fs`.
- **Safety:** `gptfix`/`growpart`/`pvresize` sind vom protected-disk-Guard
  ausgenommen — sie sind rein additiv und online, sonst wäre der Hauptfall (eine
  gewachsene VM-**System**platte) nie behandelbar. Tabellenänderung wird vorher per
  `sfdisk -d` gesichert.
- **Live verifiziert** auf test-deployment (Proxmox `qemu/<vmid>/resize`): Systemplatte
  32→40→44 GB; nach Refresh erscheint das Banner, ein Klick + Apply ergab
  sda1 = ganze Platte, PV/VG 44 g, `/var` 10G → 22G — im laufenden Betrieb, ohne
  Reboot und ohne Unmount.

## 8b. Die KI bedient den Partition-Editor (MCP)

Der Editor ist als MCP-Tools exponiert, damit die KI ihn selbst fährt — **eine Logik,
mehrere Oberflächen** (UI, REST, MCP, Chat):
- `disk_layout(host)` — Live-Scan (read-only).
- `disk_plan_preview(host, ops)` — Op-Queue → exakte Kommandos + Safety-Verdikt, ohne
  Ausführung. **Immer vor Apply.**
- `disk_plan_apply(host, ops)` — führt die Queue aus; dasselbe Safety-Gate wie UI/REST.
- Chat-KI: read-only `disk_layout` in `chat_tools.py` (v1 read-only-Doktrin);
  mutierende Ops laufen über die separat auditierten MCP-Tools.

Die Op-Formate stehen in den Tool-Beschreibungen (server.py); `ops` ist eine geordnete
Liste, jede Op ein Dict mit `op`-Feld (mklabel/mkpart/mkfs/label/mount/umount/delete/
resize/lvextend/lvreduce).

## 9. Risiken / offen (Stand nach der Umsetzung)

Adressiert:
- **Datenverlust** — Danger-Formulare mit Begründung, `sfdisk -d`-Tabellen-Backup vor
  jeder Tabellenänderung, Preview der exakten Kommandos, Busy-Guard, und
  `safety_check` nennt bei einer Verweigerung den **Grund**.
- **Root-/Boot-Platte** — Platten mit gemountetem Dateisystem sind hart geschützt;
  ausgenommen ist nur die rein additive, online-sichere Kette
  `gptfix → growpart → pvresize → lvextend` (genau der Fall „VM-Systemplatte
  vergrößert"), live verifiziert.
- **Kein echter parted-Dry-run** — Preview zeigt die kompilierten Kommandos +
  Safety-Verdikt, Tabellen-Backup als Rückfallebene.
- **Komplexe Stacks** — LVM (extend/reduce/pvresize), LUKS (format/open/close),
  ZFS (Pools/Datasets/Snapshots/Quota) sind umgesetzt und live getestet.
- **Tool-Verfügbarkeit** — Scan meldet fehlende Tools, ein Klick installiert sie;
  Apply installiert selbst nach (§8d).
- **Reihenfolge/Alignment** — `parted -a optimal` beim Anlegen; Resize/Move rechnen in
  MiB (also 1-MiB-aligned); Shrink-Reihenfolge fs→Partition, Grow Partition→fs;
  Move kopiert rückwärts bei Überlappung (§8e).

Offen:
- **Software-RAID (mdadm)** — Arrays werden noch nicht angezeigt oder verwaltet.
  Das ist die letzte größere Lücke gegenüber typischen Linux-Servern.
- **Rehearsal-first** für destruktive Ops (Anknüpfung an docs/test-systems.md).
