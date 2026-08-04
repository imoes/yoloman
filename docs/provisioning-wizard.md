# Provisioning-Wizard + Deployment-Templates

> Eigener Plan. Baut auf der bestehenden Disk-Templates-/PXE-Fläche auf
> (`docs/pxe-baremetal-imaging.md`), ersetzt sie nicht.

## Kontext

Die Provisioning-Seite (`features/disk-templates`) ist heute ein 3-Spalten-Formular: Templates links,
Disk-Geometrie (nur Prozent-Slider) Mitte, „Provision" (Hostname/MAC/Netz) rechts, darunter das Lab. Der
Operator will es auf das Niveau von Rollen/Features heben:

1. **Wizard** wie `add-roles-wizard` (linke Schrittleiste, Weiter/Zurück) statt des flachen Formulars.
2. **Config-Policy anwenden** — Config dem Zielhost mitgeben, wie es der Management-Tab erlaubt; konvergiert
   nach dem ersten Boot, genau wie Rollen.
3. **Volume-Größen in GB** zusätzlich zu Prozent, pro Template umschaltbar.
4. **UEFI/BIOS** eines Disk-Images anzeigen.
5. **Fertige Deployments** unten in einer schließbaren Log-Box.
6. **Deployment-Templates** — alles außer Hostname/MAC bündeln, beim Anwenden nur noch die Rest-Felder.
7. **Custom-Rollen** mit dem Deployment verknüpfen.

Entscheidungen (mit dem Operator): GB **+** Prozent umschaltbar; Deployment-Template speichert alles außer
Hostname/MAC (neue Tabelle); Config = wie Management-Tab (Config-Templates/Policies an den Host gebunden).

## Was schon da ist (nicht neu bauen)

- **UEFI/BIOS steckt im Manifest**: `imaging.layout_to_dict` liefert `label` (gpt|dos) und `partitions[].kind`
  (`uefi`/`bios_boot`/`linux`/`lvm`/`swap`). Firmware = UEFI, wenn eine ESP/`uefi`-Partition existiert, sonst
  BIOS. Nur noch in `ImageOut.from_model` ableiten und ausgeben — keine Capture-Änderung.
- **grow_policy** (`imaging.plan_restore`): role→Prozent, Summe 100; verteilt den Restplatz auf
  root/var/home (LVM). `api/images.py:patch_image` speichert sie schon.
- **Wizard-Muster**: `features/hosts/management/roles/add-roles-wizard.component.ts` (linke Schrittleiste,
  `step()`/`stepKind()`/`next()`/`prev()`, Confirm-Schritt, Live-Ergebnis).
- **Rollen/Config-Binden**: der Management-Tab bindet Rollen (`role-bindings`) und Config
  (`package-config`/OU `config_policy`) an einen Host; dieselben Endpunkte nutzen.
- **Planned Host + Arm**: `createPlannedHost` → `arm` (`api/images.py`) legt Host an und scharfschaltet den
  Restore-Job. Rollen/Config müssen an genau diesen Host gehängt werden.
- **Deployment-Log**: `DeploymentRun` (deployment_runs) existiert für Plan-/Runbook-Deployments; die
  Provisioning-Seite hat eine eigene `restore_jobs`-Liste. Die Log-Box zeigt die Restore-Jobs.

## Blöcke (jeder einzeln verifiziert + committed)

**P1 — UEFI/BIOS-Badge (Backend + UI, klein).**
`ImageOut.from_model`: `firmware: "uefi" | "bios"` aus dem Manifest ableiten (`label` + Partition-`kind`).
`images.service.ts` `DiskImage.firmware`. Badge auf der Template-Karte. Pytest für die Ableitung
(gpt+esp→uefi, dos→bios, gpt+bios_boot→bios).

**P2 — Volume-Größen GB + Prozent (Backend + UI).**
`plan_restore` bekommt einen `grow_mode` (`percent`|`absolute`): bei `absolute` sind die Werte GB je
wachsendem Volume, ein Rest-Volume (root, sonst das letzte) füllt den verbleibenden Platz; Guards
(xfs-shrink, Platz reicht) bleiben. `DiskImage.grow_mode` in Manifest/Model + `patch_image`. UI: Toggle
%/GB im Disk-Schritt. Tests: absolute Verteilung, Rest-Volume, „passt nicht"-Fehler.

**P3 — Der Wizard (UI).**
Neue `provision-wizard.component.ts` nach `add-roles-wizard`-Muster. Schritte:
Ziel (Hostname/MAC/Netz) → Disk (Image wählen, UEFI/BIOS, Volume-Größen %/GB) → Rollen (Custom-Rollen aus
`plan-library` verknüpfen, Drag/Checkbox) → Config (Config-Policies/Templates wie Management-Tab) → Review →
Deploy. Der `disk-templates`-Screen ruft ihn auf; die alte 3-Spalten-Form bleibt als „erweitert" oder
weicht dem Wizard (Entscheidung beim Bauen).

**P4 — Deployment-Templates (Backend + UI).**
Neue Tabelle `deployment_templates` {name, image_id, grow_mode, grow_policy(JSON), network(JSON),
roles(JSON), config_refs(JSON)}. CRUD unter `/api/v1/provisioning/templates`. Im Wizard „Als Template
speichern" + „Aus Template starten" (füllt alle Schritte außer Ziel). Alembic-Migration ab dem aktuellen
Head. Tests für CRUD + Anwenden.

**P5 — Log-Box unten, schließbar (UI).**
Fertige Restore-Jobs (done/failed) unten in einer Box mit Schließen-Button; pro Job der `log`-Text.
State pro Session (localStorage), damit „geschlossen" bleibt.

**P6 — Rollen + Config beim Arm verknüpfen (Backend).**
`arm` (oder ein Wrapper) nimmt optional `roles: []` + `config_refs: []` und bindet sie an den geplanten
Host (dieselben Binding-Services wie der Management-Tab), sodass sie nach dem ersten Boot konvergieren.

## Kritische Dateien

| Datei | Änderung |
|---|---|
| `bossman/bossman/api/images.py` | `ImageOut.firmware`, `grow_mode` in `patch_image`, `arm` nimmt roles/config |
| `bossman/bossman/services/imaging.py` | `plan_restore(grow_mode)` absolute-GB-Verteilung |
| `bossman/bossman/db/models.py` + alembic | `DiskImage.grow_mode`, Tabelle `deployment_templates` |
| `bossman/bossman/api/provisioning.py` (o. ä.) | CRUD `deployment_templates` |
| `bossman-ui/.../core/services/images.service.ts` | `firmware`, `grow_mode`, Template-CRUD, arm-Erweiterung |
| `bossman-ui/.../features/disk-templates/provision-wizard.component.ts` | **neu** — der Wizard |
| `bossman-ui/.../features/disk-templates/disk-templates.component.ts` | Wizard einhängen, Log-Box, UEFI/BIOS-Badge |

Wiederverwenden: `add-roles-wizard` (Wizard-Gerüst), `plan-library`/`plan.service` (Rollenliste),
Config-Binding vom Management-Tab, `shared/param-form` (Rollen-Parameter), `images.service` (arm/jobs).

## Verifikation

1. Pytest grün: Firmware-Ableitung, absolute grow-Verteilung, Template-CRUD, arm-mit-Rollen.
2. `npx ng build` grün; Wizard end-to-end im Browser (Playwright): jeder Schritt, %/GB-Toggle, UEFI/BIOS
   sichtbar, Template speichern→laden, Log-Box schließen.
3. Ein echtes Deployment über den Wizard armen; der Restore-Job erscheint, verknüpfte Rollen/Config hängen
   am geplanten Host (Management-Tab).
