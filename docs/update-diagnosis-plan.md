# Erklärbare Diagnose — Updates: „warum schlug ein Update fehl / warum liegt der Host zurück?"

## Kontext

Die erklärbare Diagnose (`docs/diagnosis.md`) beantwortet heute „warum startet der Dienst nicht". Nächste Domäne
(Nutzer-Entscheidung 2026-10-18): **Updates**. Gleicher Vertrag (evidence/findings/certainty/remedy/timeline/gaps),
gleiche Werkzeuge (Builder, Katalog, Ingest, Export, Erklärung, MCP), nur ein anderes **Ziel**: `target.kind = "updates"`
statt eines Dienstes. Keine neue Mess-Infrastruktur, wo sie schon existiert — Windows liest das vorhandene read-only
`windows_update_facts` (Pending, History mit ResultCode/HResult, letzter Lauf, WSUS, ausstehender Neustart), Linux den
Paketmanager-Zustand (apt/dnf).

## Regeln (Katalog `configs/diagnosis_rules.json`, Präfix `upd.`)

- `upd.up_to_date` (Proven) — nichts ausstehend; der „alles gut"-Zustand (kein Limbo).
- `upd.behind` (Proven) — N Updates ausstehend (Sicherheitsanteil genannt); ein Zustand, kein Fehler. Remedy: installieren.
- `upd.reboot_pending` (Proven) — ein Neustart steht aus und blockiert/verfälscht weitere Installationen.
- `upd.install_failed` (Proven) — die letzte Update-Operation schlug fehl: Windows History ResultCode=Failed mit HResult
  (in Windows' Worten), Linux dpkg/apt-Fehler. Remedy je Plattform.
- `upd.wsus_unreachable` (Likely, Windows) — Policy weist WSUS zu, aber die letzte Suche kam nicht durch.
- `upd.repo_unreachable` (Likely, Linux) — ein Repository war bei der letzten Aktualisierung nicht erreichbar.
- `upd.held` (Proven, Linux) — Pakete zurückgehalten (apt-mark hold / dnf versionlock / phased updates), mit Grund.
- `upd.dpkg_interrupted` (Proven, Linux) — dpkg wurde unterbrochen (braucht `dpkg --configure -a`).
- `upd.unexplained` (Unknown) — keine Regel trifft; nennt, was gelesen wurde und was nicht messbar war.

Gewissheit nach denselben Regeln; nichts wird erfunden; Remedy ist Vorschlag, nie Ausführung; KI erklärt nur mit
Belegpflicht. Order-Bereich 2000+ (eindeutig neben den `svc.`-Regeln).

## Blöcke (jeder einzeln getestet, Commit + CHANGELOG mit Beleg; kein Push ohne Freigabe)

- [ ] **U0 — Vertrag + Katalog.** `upd.`-Regeln im Katalog + beide Kopien (Go/C#), ein Golden-Dokument
  (`configs/schemas/diagnosis.examples/windows-update-failed.json` o.ä.), Python-Contract-Test. Fertig: Katalog in
  Python/Go/C# konsistent, Golden validiert.
- [x] **U1 — Windows-Update-Diagnose** erledigt 2026-10-18 (Agent 0.3.30): `UpdateSnapshot` + reine `UpdateRules.Diagnose`
  (install_failed/reboot_pending/wsus_unreachable/behind/up_to_date, Fehler ranken vor dem „behind"-Zustand) in
  `AgenticMcp.Agent.Diagnosis` (auf Linux testbar), `UpdateRules.FromFacts` mappt die `windows_update_facts`-Ausgabe,
  neues read-only Modul `update_diagnose` (nutzt dieselbe Facts-Sammlung — keine neue Messung). HRESULTs werden an der
  Quelle benannt (`WindowsUpdateRun.Named` jetzt public, in `WindowsUpdateFacts.Interpret` genutzt). 6 Rules-Tests +
  FromFacts-Test. **Live auf bossman-wintest:** `update_diagnose` → Ziel `updates`, Status `behind`,
  `upd.behind/Proven` („3 pending"), Evidenz aus `windows_update_facts`; der install_failed-Pfad ist unit-getestet
  gegen die reale 0x8024200D-Facts-Form.
- [x] **U2 — Linux-Update-Diagnose** erledigt 2026-10-18: `internal/diagnosis/updates.go` (UpdateSnapshot +
  `DiagnoseUpdates`-Regeln + `CollectUpdates`), read-only über apt (`apt-get -s upgrade`, `apt-mark showhold`,
  `dpkg --audit`, `/run/reboot-required`) und dnf (`dnf -q list --upgrades`, `updateinfo list security`,
  `versionlock list`); Modul `update_diagnose` (Go) registriert. Regeln: dpkg_interrupted/reboot_pending/
  repo_unreachable/held/behind/up_to_date (Fehler ranken vor dem Zustand), Sicherheitsanteil gezählt. Go-Tests grün
  (Regeln + Schema). **Live im Debian-Pod:** `update_diagnose` → Ziel `updates`, Status `behind`, `upd.reboot_pending`
  + `upd.held` (bash via apt-mark hold) + `upd.behind` aus echten apt-Daten.
- [x] **U3 — Bossman-Anbindung** erledigt 2026-10-18: `services/diagnosis.diagnose_updates` (ruft das Agent-Tool
  `update_diagnose`, prüft den Vertrag, speichert über dasselbe `store` — target_kind „updates"), MCP-Tool
  `diagnose_updates(host)`, REST `POST /api/v1/agents/{id}/diagnose-updates`, ops_guide-Eintrag. Ingest-Tests:
  gespeichert (upd.install_failed führend, target_kind updates), Agent ohne Modul → 501 benannt; 36 Tests grün.
  Live geht mit dem nächsten bossman-Rebuild (das laufende Image kennt das neue Tool noch nicht; der Agent 0.3.30 hat
  `update_diagnose`).
- [x] **U4 — Remedy mit Snapshot-Rückweg — ERLEDIGT 2026-10-19** (beide Plattformen). Windows: kein Gast-Snapshot wie
  LVM/ZFS und KB-Deinstallation nur teilweise umkehrbar → keine Remedy, benannte Lücke, die Fix (Patch-Ringe/
  `windows_update`) und echten Rückweg (Hypervisor-/VM-Snapshot) nennt (C#-Test). Linux: U4a/b/c (unten).
- **U4 — Remedy mit Snapshot-Rückweg (Nutzer-Entscheidung 2026-10-19).** Ein Update-Fix ist imperativ (installieren,
  Neustart) und nicht per before/after umkehrbar — der Rückweg ist ein **Dateisystem-Snapshot** vor dem Update, der bei
  Problemen zurückgespielt wird. Grundsatz: eine Remedy ist weiter nur ein **Vorschlag + exportiertes Playbook**
  (Vier-Augen, keine Auto-Ausführung); eine *umkehrbare* Remedy entsteht nur, wenn ein snapshot-fähiges Volume
  existiert, sonst **benannte Lücke** statt Fake-Rollback.
  - [x] **U4a — Snapshot-Fähigkeit erkennen (read-only).** Der Linux-Update-Collector liest, ob `/` auf LVM (thin/
    thick) oder ZFS liegt (findmnt/lsblk/zfs list) und füllt `SnapshotTarget {kind: lvm|zfs|none, id, reason}`. Keine
    Änderung am Host. Go-Test.
  - [x] **U4b — Remedy-Daten.** `upd.behind` (und ggf. `upd.install_failed`) tragen eine Remedy: before = Snapshot
    anlegen (`lvcreate -s` / `zfs snapshot`), action = install, rollback = Snapshot zurückspielen (`lvconvert --merge`
    + Neustart / `zfs rollback`), verify = Regel feuert nicht mehr. Nur wenn SnapshotTarget ≠ none; sonst keine Remedy
    + Lücke. Windows: Rückweg = KB-Deinstallation, wo deinstallierbar (sonst keine Remedy + Grund). Schema-Aktionen
    `install`/`restore` + `snapshot` ergänzen. Go + C#.
  - [x] **U4c — Export.** Der Ansible/PowerShell/Shell-Export erzeugt das Playbook Snapshot→Update und das
    Rollback-Playbook (Restore); DSC `not_expressible` mit Grund. Golden-Tests.
  - Export/Erklärung (GELF/Checkmk/KI) funktionieren schon über jedem Dokument. UI: später mit dem UX-Konzept.

## Wiederverwendet

Builder/Contract (`internal/diagnosis`, `AgenticMcp.Agent.Diagnosis`, `services/diagnosis_contract.py`), die
`diagnoses`-Tabelle + Ingest (`services/diagnosis.py`), Export/Remedy/Explain, das MCP-Muster. `windows_update_facts`
(read-only) als Windows-Datenquelle; der Paketmanager als Linux-Datenquelle.
