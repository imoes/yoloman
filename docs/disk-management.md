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
  + busy). NOTE: live write-op test still pending — test-deployment is a KVM VM whose
  kernel refuses unsigned out-of-tree modules (IMA/IPE), so the DKMS zfs.ko (built OK)
  can't load there; needs a host where ZFS is already loadable.
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

## 9. Risiken / offen

- **Datenverlust** — destruktive Domäne; Bestätigung, Backup, klarer Diff, Busy-Guard.
- **Root-/Boot-Platte** — online kaum sicher änderbar; solche Ops nur offline/gegen
  eine Rehearsal-/Image-Umgebung (Anknüpfung an Imaging + test-systems).
- **Kein echter parted-Dry-run** — durch Preview-Diff + Tabellen-Backup mitigiert.
- **Komplexe Stacks** (LVM/LUKS/RAID/Timescale-Hypertables auf der Platte) — Phase 1
  nur anzeigen; Bearbeiten schrittweise.
- **Tool-Verfügbarkeit am Host** — vorab prüfen.
- **Reihenfolge/Alignment** — Sektor-Alignment (1 MiB) + gparted-Reihenfolge exakt
  übernehmen, sonst Korruption/Verschnitt.
