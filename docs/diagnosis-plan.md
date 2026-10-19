# Erklärbare Diagnose in yoloman — erster Schnitt „Dienst startet nicht“ (Windows + Linux)

## Context

Der Nutzer will ein System, das einem Administrator erklärt, **warum** etwas nicht funktioniert: jede Aussage auf
Messdaten gestützt, Unsicherheit sichtbar, Reparatur als prüfbare Änderung mit Rückweg, KI erklärt nur. Sein
Observatory-Plan war für das Shellvis-Repo gedacht; entschieden ist jetzt (Nutzer): **der Kern lebt im
yoloman-Windows-Agenten**, und der erste Schnitt umfasst **Windows und Linux mit einem gemeinsamen Vertrag**. Bossman
zeigt, speichert, exportiert und erklärt beide gleich. Shellvis kann die C#-Bibliothek später referenzieren.

**Nicht vorgesehen:** Windows dekompilieren oder patchen (Lizenz; liefert keinen baubaren Code; nicht nötig — alles
über dokumentierte APIs, Lücken werden als „nicht messbar mit öffentlichen Schnittstellen“ benannt), automatische
Reparatur, Linux-Library-OS.

**Was es schon gibt (wird wiederverwendet):** Modul-Vertrag in beiden Agenten (`internal/modules/module.go`,
`windows-agent/AgenticMcp.Agent.Core/Modules.cs`, Wire-Parität per `ContractTests.cs`), Operation-Log mit stabilen
`record_id`s und `evidence`-Block (`internal/audit/ring.go`, `Agent.Core/OperationLog.cs`, Bossman
`db/models.py:3076`), `windows_eventlog`/`journal`-Module, `DeclarativeModule` (Vorher/Nachher, PowerShell-Script),
`ChangeProposal` (`services/proposals.py`), `doc_to_playbook` (`services/ansible_playbook.py`), MCP-Tool-Muster
(`mcp/server.py` + `ops_guide.py` + `tests/test_mcp_server.py`), der Linux-Ursachenklassifikator `SHIPPED_CAUSES`
(`tools/package_e2e_bossman.py:322-365`, bisher nur im Testwerkzeug), Pod-Testbett (systemd-Host-Images in minikube),
Windows-Testhost `bossman-wintest` (Server 2022, deutsche Locale).

## Der gemeinsame Vertrag

- `configs/schemas/diagnosis.schema.json` (JSON Schema 2020-12): Diagnosis
  `{diagnosis_id, host, platform, target, collected_at, evidence[], findings[], timeline[], gaps[]}`.
  - **Evidence** `{id, source, observed, fact, raw}` — stabile IDs: `scm:config:<svc>`, `evt:System:7000:<recordId>`,
    `systemd:show:<unit>`, `journal:<cursor>`, `lsa:rights:<sid>`, `authz:<sid>:<path>`.
  - **Finding** `{rule_id, claim, certainty: Proven|Likely|Unknown, evidence_ids[≥1], precedent?, remedy?}`;
    `Unknown` trägt einen benannten Gap.
  - **Precedent** `{evidence_id, change, observed, gap_seconds}` — Korrelation, hebt Gewissheit nie über `Likely`.
  - **Remedy** `{target, before, after, rollback, verify}` — `verify` sind Daten (Soll-Zustand + „rule_id feuert
    nicht mehr“), kein Skript.
- `configs/diagnosis_rules.json`: Regelkatalog (`svc.dependency_failed`, `svc.image_missing`, `svc.logon_failed`,
  `svc.logon_right_missing`, `svc.access_denied`, `svc.timeout`, `svc.disabled`, `svc.exits_immediately`, plus
  Linux-Ursachen aus `SHIPPED_CAUSES`: `svc.user_missing`, `svc.exec_missing`, `svc.crash`, `svc.masked`, …), je mit
  `platforms[]`, Bedingungen pro Gewissheit und Remedy-Zielart.
- Golden-Dokumente `configs/schemas/diagnosis.examples/*.json` (windows-logon-right, windows-dependency,
  linux-203-exec, unknown-gap). Geprüft in **allen drei** Sprachen: pytest validiert gegen das Schema (`jsonschema` ist
  da), Go marshalt byte-gleich zu den Goldens (+ `google/jsonschema-go`), C# `DiagnosisContractTests` byte-gleich im
  Stil der vorhandenen Wire-Tests; jede ausgegebene `rule_id` muss im Katalog stehen.
- `docs/diagnosis.md`: Modell, Regeln, Gewissheitsregeln, Grenzen — als Prosa.

**Wo was erzwungen wird:** Die **Agenten** vergeben Gewissheit (deterministisch; Finding-Konstruktor verweigert leere
oder fremde Evidence-IDs; `Proven` nur bei direkter Messung, z. B. Win32ExitCode, ExecMainStatus=203; `Unknown` nur mit
Gap). **Bossman** prüft beim Eingang erneut (ältere Agenten im Fleet) und speichert Verstöße als
`contract_status=violation` mit Grund — nie verworfen, nie „repariert“, Gewissheit wird nie angehoben, die KI setzt sie
nie. Regeln sind reine Funktionen über einen gesammelten **Snapshot** (testbar ohne Win32/systemd).

## Blöcke (jeder einzeln getestet, dann Commit + CHANGELOG mit Beleg; kein Push ohne Freigabe)

Stand: B0–B13 erledigt (Restpunkte je Block notiert) (siehe Abhaken unten an jedem Block).

- [x] **B0 Vertrag** — Schema, Katalog, Goldens, `docs/diagnosis.md`, `bossman/tests/test_diagnosis_contract.py`.
Fertig: Goldens validieren; Katalog deckt Windows-Regeln 1–7 und die Linux-Ursachen.

- [x] **B1 Go-Kern** — `internal/diagnosis/{model,invariants,timeline,rules}.go` + Tests. Fertig: Golden-Gleichheit,
Invarianten-Tests (kein Finding ohne Evidence, kein Unknown ohne Gap, keine hängenden IDs).

- [x] **B2 Linux-Kollektor + Modul** — `internal/diagnosis/collect_systemd.go`: `systemctl show` (Result, ExecMainCode,
ExecMainStatus, NRestarts, InvocationID, FragmentPath, DropInPaths, User, LoadState, UnitFileState), Requires/After-Kette
rekursiv, Journal der aktuellen Invocation. `internal/modules/journal.go` liefert zusätzlich `__CURSOR`,
`_SYSTEMD_INVOCATION_ID`, `MESSAGE_ID`. Neues read-only Modul `internal/modules/service_diagnose.go`
(`include_snapshot`), registriert in `server/modules.go` und `run-module`. Die `SHIPPED_CAUSES`-Muster wandern als Regeln
in den Agenten. Fertig: `go test ./internal/...`; `run-module service_diagnose` im Pod.

- [x] **B3 Linux-E2E** — `bossman/bossman/tools/diagnosis_probe_linux.py` auf dem vorhandenen Pod-Runner: kaputte Units
(fehlendes ExecStart → 203/EXEC, `User=nosuchuser` → 217/USER, `Requires=` auf scheiternde Unit, maskiert,
`/bin/false`, SIGSEGV, `TimeoutStartSec=1`, start-limit-hit, StateDirectory-Rechte) in debian-trixie-systemd und
almalinux9-systemd. Fertig: jede Probe liefert ihre `rule_id`; Vergleichstabelle gegen `SHIPPED_CAUSES` über den
package_e2e-Korpus, jede Abweichung begründet. Danach nutzt `package_e2e_bossman --classify` das Agent-Modul;
`SHIPPED_CAUSES` bleibt nur als Gegenprobe.
  - [x] Gegenprobe erledigt 2026-10-17 (Agent 0.57.91, 39 Rollen, deren Dienst im Paket-E2E nicht lief): 33 stimmen
    überein, 2 Agent genauer (iscsi-target: Abhängigkeit statt „kein Journal“; espeakup: Startlimit statt
    „unklassifiziert“), 2 begründet abweichend — svxlink (Ursache steht nur in der eigenen Logdatei des Dienstes, die
    der Agent nicht liest) und comitup (Klassifikator „Hardware“ wegen des Worts NetworkManager; der Agent liest den
    fehlenden D-Bus-Dienst als `svc.peer_unreachable`) —, 2 ohne Diagnose: ferm und connman sperren den Agenten selbst
    aus (Firewall / Netzwerkverwaltung im Pod). Dabei gefunden und behoben: unvollständig portierte Journal-Muster
    (13 Fälle), `activating (auto-restart)` als „startet“ statt als Fehlschlag (3 Fälle), ein Abbildungsfehler im
    Vergleich (needs-site-config = config_incomplete ODER condition_failed). Ein `--classify`-Umbau steht nicht an:
    das Werkzeug trägt die Agent-Diagnose jetzt in jeder Baseline-Zeile mit (`diagnosis_compared`).

- [x] **B4 C#-Kern** — neues Projekt `windows-agent/AgenticMcp.Agent.Diagnosis` (**net10.0**, ohne Win32 — damit die
Linux-Tests laufen), in `.slnx` und von `Agent.Tests` referenziert. Fertig: `dotnet test` grün inkl. Golden-Gleichheit.

- [x] **B5 Windows-Kollektoren I** — `AgenticMcp.Agent.Windows/Diagnosis/{ScmCollector,EventCollector,ImageCollector}.cs`:
QueryServiceConfig/Config2, QueryServiceStatusEx, Abhängigkeitskette inkl. Gruppen, SCM-Ereignisse 7000/7001/7003/7009/
7011/7022/7023/7024/7031/7034/7038/7041/7045 und Application 1000/1001/1026 per `EventLogReader` + XPath (EventData,
nicht Meldungstext; Dienste in Ereignissen per **Anzeigename** aus QueryServiceConfig — lokalisiert), Image vorhanden /
Pfad ohne Anführungszeichen. 1053/1058 sind Win32-Codes in den Insertion-Strings, keine Event-IDs. Modul
`service_diagnose` read-only in `Program.cs` registriert. Testdienst-Binary `AgenticMcp.Agent.ProbeService`
(`--mode=exit-specific:42|crash|hang`, nicht im MSI). Fertig: Proben für Regeln 1, 2, 5, 6, 7 auf bossman-wintest grün;
aufgenommene Snapshots als Replay-Fixtures unter `Agent.Tests/fixtures/diagnosis/windows/`.
  - [x] ProbeService erledigt 2026-10-17: `windows-agent/AgenticMcp.Agent.ProbeService` (Einzeldatei, wird von der Probe
    gebaut und vom Host selbst geholt); exit-specific:42 → `svc.exits_immediately` Proven, crash → `svc.crash` Proven,
    hang → `svc.timeout` **Likely** (gemessen: ein hängender Start bleibt START_PENDING ohne jedes Ereignis — Regel neu
    in Agent 0.3.8/0.3.9). Windows-Probe 17/17 inkl. 4 Reparaturen.

- [x] **B6 Windows-Kollektoren II** — `AccountCollector` (NetUserGetInfo lokal; LsaEnumerateAccountRights +
LsaEnumerateAccountsWithUserRight für Gruppenrechte, Deny-Rechte), `AccessCollector` (AuthzInitializeContextFromSid +
AuthzAccessCheck auf Image und Ordner, verweigernde/fehlende ACE), `TrustCollector` (WinVerifyTrust). Domänenkonten,
gMSA, virtuelle Konten ohne DC-Auflösung → benanntes `Unknown`. Fertig: Proben für Regeln 3 und 4 grün.
  - [x] Erledigt 2026-10-17 (Agent 0.3.2): AccountCollector (SID-Auflösung, NetUserGetInfo, LSA-Rechte direkt und
    über lokale Gruppen, Deny-Recht) und AuthzAccessCheck auf Image + Ordner im selben Kollektor; Probe 13/13
    (Recht fehlt per LSA ohne Start, deaktiviertes Konto, gelöschtes Konto, Deny-ACE auf dem Image).
  - [x] Erledigt 2026-10-18 (Agent 0.3.26): `SignatureCollector` (WinVerifyTrust, inkl. Sicherheitskatalog — ein
    katalogsigniertes cmd.exe wird korrekt als „signed and trusted" erkannt, nicht als „unsigned"); neue Regel
    `svc.blocked_by_policy` (AppLocker 8004 / Code Integrity 3077 blockiert das Image), Signatur als Evidenz/Kontext.
    Ein nicht eindeutig geprüfter Zustand wird ehrlich als „keine eingebettete Signatur (Katalog nicht bestätigt)"
    gemeldet, nie falsch als „nicht signiert". Block-Regel über aufgezeichnete Ereignisse getestet (AppLocker am
    Host zu erzwingen wäre eine Sicherheitsrichtlinienänderung); Signatur live an cmd.exe/ProbeService bewiesen.

- [x] **B7 Vorgeschichte, beide Plattformen** — Windows: LastWriteTime des Service-Schlüssels, Image-mtime, 7045/7040,
MsiInstaller 1033/11707, WindowsUpdateClient 19/20, Reliability-Records (auf Server 2022 evtl. aus → Unknown).
Linux: Unit-/Drop-in-mtime, `dpkg.log`/`dnf history`, `dpkg -S`/`rpm -qf`. Fertig: Probe „ändern, dann brechen“ liefert
Precedent mit Zeitabstand.
  - [x] Erledigt 2026-10-17 (Linux 0.57.90, Windows 0.3.3): Builder.Change/Precede in Go und C# (Fenster 7 Tage,
    Ziel vor Host); Linux ctime statt mtime (Paket-mtime = Build-Datum, gemessen), dpkg.log/rpm mit /usr-Merge-Pfad;
    Windows Schlüssel-LastWriteTime, Image Erstellung/Schreibzeit, 7045/7040, MsiInstaller/WindowsUpdateClient 19.
    Proben: Linux 28/28, Windows 14/14 inkl. „ändern, dann brechen“.
  - [ ] Offen: Reliability-Records (nicht gelesen), dnf history (rpm-Installzeit reicht für den Precedent).

- [x] **B8 Bossman-Eingang** — `services/diagnosis.py` (validieren, speichern), Alembic-Migration `diagnoses`
(Schlüssel `(diagnosis_id, evidence_id)` — recordIds wiederholen sich nach Log-Löschung), MCP-Tool
`diagnose_service(host, name)` in `mcp/server.py`, Eintrag in `ops_guide.py`, Chat-Tool in `chat_tools.py`. Fertig:
`test_mcp_server.py` mit Fake-Client, ein Windows- und ein Linux-Golden durch denselben Codepfad.
  - [x] Erledigt 2026-10-17: Tabelle `diagnoses` (eine Zeile je Lauf, Evidence im Dokument — kein eigener Schlüssel
    `(diagnosis_id, evidence_id)`, weil Evidence nur innerhalb ihres Dokuments zitiert wird; eindeutig ist
    `(agent_id, diagnosis_id)`), REST `POST /agents/{id}/diagnose`, `GET /agents/{id}/diagnoses`,
    `GET /diagnoses/{id}`, MCP `diagnose_service` + `recent_diagnoses`, Guide- und Chat-Eintrag;
    `tests/test_diagnosis_ingest.py` (Windows- und Linux-Golden, Verstoß gespeichert und nicht repariert, Agent ohne
    Modul benannt). Live: bossman-wintest gespeichert, pve1 (0.57.42) → 501 mit Grund.

- [x] **B9 Exporter (nur in Bossman, nicht doppelt in den Agenten)** — `services/diagnosis_export.py`: Checkmk
`<<<local>>>`-Zeile mit Ursache als Text, GELF je Finding/Evidence mit `_correlation_id=diagnosis_id` (optional
UDP/TCP-Versand), Ansible mit FQCN (`ansible.windows.win_service`/`win_user_right`/`win_acl`/`win_regedit`;
`ansible.builtin.systemd_service`/`user`/`file`), DSC v3 (vorher prüfen, ob `Microsoft.Windows/Service` nativ existiert;
sonst WindowsPowerShell-Adapter mit `PSDscResources/Service`), PowerShell-Vorschlag. Fertig: Golden-Tests je Exporter;
Ansible-Ausgabe besteht `ansible-lint`.
  - [x] Erledigt 2026-10-17: Checkmk, GELF, Ansible (ansible-lint sauber, apply + rollback), DSC v3 (nativ
    `Microsoft.Windows/Service` existiert seit DSC 3.2 — offene Frage damit beantwortet; Benutzerrecht/ACL ohne native
    Ressource → `not_expressible`), PowerShell. Auf bossman-wintest angewandt (`diagnosis_probe_windows --repair`):
    disabled, logon-right (Ereignis + LSA), access-denied — Regel danach weg, nach Rollback wieder da; dabei
    gefunden: ein vor der Reparatur aufgezeichnetes 7041 hielt die Regel fest (Agent 0.3.4: LSA schlägt Historie).
  - [x] GELF-Versand erledigt 2026-10-18 (Nutzer: „Füge einen graylog Container und teste es"): `services/gelf_send.py`
    sendet die GELF-Nachrichten über UDP (mit Chunking nach GELF-Spec, wenn eine Nachricht zu groß für ein Datagramm
    ist) oder TCP (NUL-terminierte Frames); `POST /api/v1/diagnoses/{id}/export/gelf/send` schaltet erst mit
    `BOSSMAN_GELF_HOST` scharf (sonst 422 mit Grund, Verbindungsfehler 502 mit Grund — nie stiller Drop). Dev-Stack:
    Compose-Profil `graylog` (Graylog 6.1 + zwingendes MongoDB + OpenSearch 2.15, WebUI 127.0.0.1:9000 admin/admin).
    Live geprüft: eine echte `windows-logon-right`-Diagnose über UDP → 6 Nachrichten (1 Finding
    `svc.logon_right_missing` Proven + 5 Evidenzen) in Graylog, alle GELF-Felder intakt, über Graylogs eigene Such-API
    per `correlation_id` bestätigt. Gemessen: der GELF-Zeitstempel ist die Messzeit (`collected_at`), nicht die
    Sendezeit — eine „letzte Stunde"-Suche verfehlt ältere Befunde (korrektes Verhalten, in docs/diagnosis.md notiert).
    Tests: `test_gelf_send.py` (5: UDP-Einzel/Chunking, TCP-Framing, kein-Host, falsches Protokoll) + Endpunkt-Test in
    `test_management_api.py` (422 ohne Ziel; 200 + empfangene Datagramme mit Korrelations-ID + Finding mit Ziel).
  - [x] Ansible-Export gegen echten Host erledigt 2026-10-18 (Linux-Teil): `tools/ansible_remedy_probe_linux.py` bricht
    eine Unit, diagnostiziert sie mit dem Agent-Modul, exportiert den Remedy und fährt apply UND rollback über die
    `kubernetes.core.kubectl`-Connection (kein SSH, Module laufen im Pod) gegen einen echten systemd-Pod. Zwei Fälle mit
    je eigenem FQCN-Modul, beobachtbarer Zustandswechsel: user-missing (`ansible.builtin.user`) Konto ABSENT→PRESENT→
    ABSENT (per getent); masked (`ansible.builtin.systemd_service`) is-enabled masked→static→masked. Beide rc=0,
    changed, `not_expressible` leer. Gemessen und notiert: das Anlegen des Kontos räumt `svc.account_missing` NICHT von
    selbst ab, weil `systemctl show` bis zum Neustart die letzte (fehlgeschlagene) Invocation meldet — der beobachtbare
    Zustand (getent) ist der Nachweis, nicht die Re-Diagnose; bei masked flippt die Re-Diagnose mit
    (svc.disabled→svc.stopped_cleanly→svc.disabled). Ergebnis: configs/ansible_remedy_probe_linux.json.
  - [ ] Offen: Windows-Ansible-Export (`win_service`/`win_user_right`/`win_acl`) gegen einen echten Host — braucht WinRM
    zum Testhost (bisher nur gelintet).

- [x] **B10 Remedy als Vorschlag** — `ChangeProposal.kind="remedy"`: `payload` = Remedy + diagnosis_id/rule_id/evidence_ids,
`preview` = Vorher/Nachher + alle Exporte. `approve()` protokolliert und hängt die Artefakte an, ruft **nie** den Agenten
(Test: Fake-Client bekommt null Aufrufe); jeder Ausführungsversuch wird mit Grund verweigert. Freigabe mit Vier-Augen
wie bei Rollen-Deployments (Ersteller sieht „Freigeben“ ausgegraut mit Grund).
  - [x] Erledigt 2026-10-17: `proposals.create_remedy_proposal` / `approvable` / Remedy-Zweig in `approve` (Status
    `approved`, `executed: false`, Artefakte angehängt, kein Agent-Client — Test), REST `POST /diagnoses/{id}/propose`,
    MCP `propose_remedy` (requested_by `ai:…`), `can_approve`/`cannot_approve_reason` je Aufrufer in der
    Proposal-API; UI: Knopf „Approve (does not run it)“ ausgegraut mit Vier-Augen-Grund, Exporte lesbar.
    Playwright `e2e/diagnosis.spec.ts` gegen bossman-wintest grün; Konsistenz-Crawler 57/57.

- [x] **B11 KI-Erklärung mit Belegpflicht** — `services/diagnosis_explain.py`: Das Modell liefert strukturiert
`[{text, evidence_ids[]}]` (kein Satz-Splitting deutscher Prosa). Deterministische Nachprüfung markiert „nicht belegt“,
wenn ein Satz keine ID hat, eine fremde ID zitiert, oder Dienstname/Konto/Exit-Code/Zahl/Zeitpunkt nennt, die nicht im
`fact`/`raw` der zitierten Evidence stehen. Gewissheit und Unknown-Lücken schreibt der Code wörtlich, nie das Modell.
Ohne Modell: Vorlage aus Claim + Facts. Tests mit vorgefertigten Modellantworten (erfundene ID, fehlende ID, falscher
Exit-Code, ausgelassenes Unknown).
  - [x] Erledigt 2026-10-17: `services/diagnosis_explain.py` (Schema `{sentences:[{text,evidence_ids}]}`, Prüfung,
    Code-Kopf mit Gewissheit/Precedent/Remedy/Lücken, Vorlage), `GET /diagnoses/{id}/explain`, MCP
    `check_explanation`; 7 Tests mit vorgefertigten Antworten (erfundene ID, fehlende ID, falscher Fehlercode,
    Gewissheitswort, ausgelassenes Unknown, Modell fällt aus) + MCP-Test. Die Prüfung fing die eigene Vorlage
    (berechnete Sekunden statt gemessener Zeit) — Vorlage nennt jetzt die gemessene Zeit, Remedy steht im Kopf.
  - [x] Live 2026-10-17 mit dem lokalen llama.cpp (Entscheidung des Nutzers, nicht OpenRouter): Windows 4/4 belegt,
    Linux ein Fehlalarm („Remediation-Verfahren“) → Regel für deutsche Komposita. Grenze notiert: eine Vorhersage ohne
    konkretes Token („…erfolgreich gestartet werden kann“) fängt die Prüfung nicht.

- [x] **B12 UI** — im Dienst-Snap-in (MMC, beide Familien) Aktion „Warum startet der Dienst nicht?“: Kurzantwort, Befunde mit
Gewissheits-Badge und aufklappbarer Evidence, Zeitachse, Remedy-Vorschlag mit Rückweg und Export, „nicht belegt“
sichtbar markiert. Fertig: Playwright-Szenario grün, Konsistenz-Crawler ohne neuen Verstoß.
  - [x] Erledigt 2026-10-17: `features/diagnosis/diagnosis-panel.component.ts`, Snap-in-Aktion `view: "diagnosis"`,
    Konsole graut eine Aktion aus, deren Modul der Host nicht hat (mit Grund). Playwright `e2e/diagnosis.spec.ts`:
    Windows (bossman-wintest, Dienst deaktiviert angelegt → Panel, Evidence, Erklärung ohne „not backed“, Export,
    Vorschlag), Linux (hal, fwupd-refresh), alter Agent (pve1 → ausgegraut mit Grund); Konsistenz-Crawler 57/57.
    Der lokale Dev-Agent (hal) läuft dafür jetzt 0.57.90 (alte Binärdatei als agentic-mcpd.bak-20261009).

- [x] **B13 Windows-Patches installieren (Nutzer, 2026-10-17)** — Modul `windows_update` im Windows-Agenten, über die
  Windows Update Agent API (COM `Microsoft.Update.Session`: UpdateSearcher → UpdateDownloader → UpdateInstaller),
  ausgeführt im Agenten-Dienst als SYSTEM (die Installations-API verweigert Remote-/Nicht-SYSTEM-Aufrufer).
  - Parameter wie `ansible.windows.win_updates`: `state` searched|downloaded|installed, `category_names`
    (SecurityUpdates, CriticalUpdates, UpdateRollups, DefinitionUpdates …), `accept_list`/`reject_list` (KB oder
    Titel-Muster), `reboot` never|if_required (Standard never), `server_selection` default|windows_update|wsus
    (WSUS-Zuweisung per GPO wird respektiert und genannt).
  - Schreibend und write-gated; `dry_run` liefert die Liste, die installiert würde (KB, Titel, Kategorie, Größe,
    „braucht Neustart“), nichts wird geladen.
  - Windows' eigene Wörter unverändert: ResultCode je Update (Succeeded, SucceededWithErrors, Failed, Aborted) und
    HResult; ein ausstehender Neustart ist ein benannter Zustand `reboot_required`, kein Erfolg und kein Fehler.
  - Danach verifiziert: neue Suche + Update-Verlauf (QueryHistory) zeigen das KB als installiert — nicht der
    Rückgabecode.
  - Lang laufend: Fortschritt und Ergebnis ins Operation-Log; Zeitüberschreitung ist `timed-out`, nicht `error`;
    Bossmans Agent-Client führt `windows_update` als langes Werkzeug.
  - Read-only Gegenstück `windows_update_facts`: installiert (Verlauf + Win32_QuickFixEngineering), ausstehend,
    letzte Suche, Neustart ausstehend (vorhandenes `pending_reboot`).
  - Rückweg: deinstallierbare Updates per `wusa /uninstall /kb:` (Ergebnis benannt, wenn ein Update nicht
    deinstallierbar ist).
  - Anbindung: Diagnose nutzt den Update-Verlauf als Vorgeschichte und Zeitachse (B7, „was hat sich seit gestern
    verändert“); Remedy-Art `package` wird auf Windows ein KB; Export als `ansible.windows.win_updates`; in Bossman
    das MMC-Snap-in „Windows Update“, die Software-Compliance-Ansicht und Rollout-Wellen als Patch-Ringe.
  - **CVE-Liste wie bei Linux (Nutzer, 2026-10-17):** derselbe Weg wie RedHat (`dnf updateinfo` → `HostCve`):
    `windows_update_facts` liefert je ausstehendem Update seine `CveIDs`, `KBArticleIDs`, `MsrcSeverity` und
    Produkt direkt aus der Windows Update Agent API (offline, keine zweite Quelle nötig). `services/cve_correlate.py`
    bekommt den Windows-Zweig wie den dnf-Zweig: Zeilen in `host_cves` mit `package` = KB, `fixed_version` = KB,
    `source_package` = Produkt/Titel, `severity` = MsrcSeverity in Windows' eigenen Wörtern (Critical, Important,
    Moderate, Low — nicht auf Debian-Stufen umgebogen), `distro` = windows-<Build>. Damit erscheinen Windows-Hosts in
    `/api/v1/security/cves`, `/security/summary` und der Sicherheitsansicht wie Linux-Hosts, und
    `/security/bulk-update` installiert die gewählten KBs über `windows_update` (`accept_list`). Wo die API keine
    CVE-Zuordnung liefert (WSUS mit gekürzten Metadaten), wird das als benannte Lücke angezeigt; die MSRC-CVRF-API
    (KB → CVE, CVSS) ist der Nachtrag dafür, nicht der Normalweg. Fertig: auf bossman-wintest stehen die ausstehenden
    Updates mit ihren CVEs in der Sicherheitsansicht, ein Bulk-Update installiert ein KB und die Zeilen verschwinden
    nach der nächsten Sammlung.
  - **Gemessen 2026-10-17 (bossman-wintest, Microsoft Update):** die Windows Update Agent API liefert für KEINES der
    4 ausstehenden Updates `CveIDs` — auch nicht für das .NET-Sicherheitsupdate (MsrcSeverity „Important“); das
    September-Kumulativupdate hat nicht einmal eine MsrcSeverity. Die MSRC-CVRF-Daten (KB → CVE, Schweregrad) sind damit
    der Normalweg, nicht der Nachtrag; Bossman lädt sie (öffentliche Daten, es geht nichts vom Host hinaus).
  - [x] Schritt 1 erledigt 2026-10-17 (Agent 0.3.5): `windows_update_facts` (read-only, COM über die PowerShell-Brücke,
    Auslegung testbar in `AgenticMcp.Agent.Modules/WindowsUpdateFacts.cs` mit aufgenommener Antwort), live 4 ausstehend.
  - [x] Schritt 2 erledigt 2026-10-17: `CveFeed` lädt die letzten `cve_msrc_months` (6) MSRC-CVRF-Dokumente zu einem
    KB-Index (Cache windows.json), `correlate_windows` (CveIDs des Hosts zuerst, sonst MSRC; KBs ohne CVE werden
    benannt), `collect_host` liest Windows-Hosts über `windows_update_facts` (vorher fielen sie still aus der Runde);
    Sicherheitsansicht rangiert/zählt Schweregrade ohne Groß-/Kleinschreibung. Live: bossman-wintest 645 CVEs
    (61 Critical, 584 Important) über KB5122882; KB5128928 (.NET) ohne CVE in den MSRC-Daten.
  - [x] Schritt 3 erledigt 2026-10-17 (Agent 0.3.6): `windows_update` (Auswahl wie win_updates in
    `WindowsUpdateSelection`, Ergebnis + Verifikation in `WindowsUpdateRun`: `installed` nur wenn ein neuer Lesevorgang
    es bestätigt, sonst `unverified`; `reboot_required` eigener Ausgang), Bossman `/security/bulk-update` installiert
    auf Windows-Hosts die KBs, die ihre CVEs schließen. Live: Defender-Definitionen (KB2267602) installiert und
    verifiziert in 22 s; .NET-Kumulativupdate KB5128928 → `reboot_required`, Host NICHT neu gestartet; Bulk-Update
    (Trockenlauf) wählt genau KB5122882.
  - [x] Letztes Kriterium erledigt 2026-10-17 (Nutzer: installieren + Neustart): erster Versuch `Failed 0x8024200D`
    (WU_E_UH_NEEDANOTHERDOWNLOAD, Neustart des .NET-Updates stand aus) → Agent 0.3.7 nennt HRESULT-Namen; nach dem
    Neustart installierte das Bulk-Update KB5122882 in 742 s → `reboot_required` → Neustart → Verlauf `Succeeded`,
    nicht mehr ausstehend, die 645 Zeilen weg. Danach bietet Windows das Oktober-Kumulativupdate KB5126655 an
    (977 CVEs) — nicht installiert, über die Freigabe hinaus.
  - [x] MMC: das Snap-in „Software updates“ dient beiden Familien (`any_of`): auf Windows „Windows Update — pending“
    (mit „Install this update“ und „Install updates…“, Vorschau zuerst) und „Update history“; Playwright grün.
  - [x] Rückweg (Agent 0.3.10/0.3.11): `windows_update state=removed` mit ausdrücklich genannten KBs, wusa-Exitcodes in
    Windows' Worten (0, 3010 = reboot_required, 0x00240007 = nicht installiert), Prüfung durch neues Lesen; was Windows
    Update als nicht deinstallierbar führt (kombiniertes SSU+LCU) und was nur Windows Update kennt (.NET-Rollup — fehlt in
    Get-HotFix, gemessen) wird mit Grund verweigert. Auf bossman-wintest als Trockenlauf geprüft.
  - [x] Patch-Ringe (2026-10-18): ein Patch-Ring ist ein gewöhnlicher gestaffelter Rollout (Lücke #8), dessen
    Wellen-Aktion das `windows_update`-Modul ist — canary → Ring 1 → Ring 2, das Health-Gate, Pause/Abbruch, Dry-Run
    und die Oberfläche übernehmen sich, ein KB landet nie auf der ganzen Flotte auf einmal. `services/patch_ring.py`
    (ein `windows_update`-Schritt, nach Signatur wiederverwendet; `reboot=never` als Standard, damit eine Welle den
    Agenten nicht mitten im Schritt wegreißt; kein `when`-Guard — ein fehlbewerteter Guard überspränge die Installation
    still; nicht-Windows-Hosts im Scope werden mit Grund fallengelassen, nichts verschwindet still), REST
    `POST /api/v1/patch-rings` (Scope expandieren, Windows behalten, Wellen planen, Runbook sicherstellen, Rollout in
    `status=pending` — nichts startet bis `POST /rollouts/{id}/start`, `dry_run` Standard True), MCP `create_patch_ring`.
    4 Tests. Live auf bossman-wintest (Trockenlauf, Host-Scope, accept KB2267602): create 200, `windows_hosts=1`,
    Runbook „Windows patch ring · KB2267602 [e278cdcf6f]“, eine canary-Welle, Rollout gestartet → `done`, Welle
    „0/1 newly CRIT (0% vs gate 0%)“ gesund, nichts installiert. Nur ein Windows-Host in der Dev-Flotte, daher ließ sich
    die Mehr-Ring-Progression nicht end-to-end zeigen.
  - [ ] Offen: eine echte Deinstallation auf dem Testhost (Freigabe nötig).
  - Fertig: auf bossman-wintest Suche, Dry-Run und Installation eines kleinen, häufigen Updates (Defender-
    Definitionsupdate) mit Verifikation im Verlauf; ein Update, das Neustart braucht, meldet `reboot_required` ohne
    neu zu starten; Tests für Parameter-Prüfung und Ergebnisabbildung unter Linux mit aufgenommenen Antworten.

- [x] **B14 Hänger und Abstürze verstehen: Wartekette und Speicherabbild (Nutzer, 2026-10-18)** — die KI analysiert
  kein Speicherabbild „roh“ und es wird nichts dekompiliert: der Agent misst, die KI erklärt mit Belegpflicht (B11).
  Erledigt 2026-10-18: alle Teilschritte auf echten Hosts verifiziert. Der ursprünglich geplante Minidump-Weg
  (WER LocalDumps / `MiniDumpWriteDump`) wurde durch den datenschutzfreundlicheren Weg OHNE Abbild abgelöst — die
  Absturzstelle kommt aus Ereignis 1000 + öffentlichen Symbolen (Windows) bzw. der Kernel-Fault-Zeile + ELF/debuginfod
  (Linux), der Hänger aus der Wartekette (Windows) bzw. `wchan` je Thread (Linux); so verlässt nie ein Abbild den Host.
  Offen nur als schmaler, späterer Schritt: ein echter Managed-Stack-Dump (ClrMD) jenseits der benannten WCT-Grenze.
  - [x] Schritt 1 erledigt 2026-10-18 (Agent 0.3.14/0.3.15): `WaitChainCollector` (GetThreadWaitChain je Thread bei
    START/STOP_PENDING), Evidenz `wct:<pid>:<tid>`, neue Regel `svc.deadlock` (Katalog + Kopien). ProbeService
    `--mode=deadlock` mit NATIVEN Mutexen: auf bossman-wintest bewiesener Zyklus (Thread → Mutex b → Thread → Mutex a →
    zurück). Gemessen: .NET `Mutex.WaitOne` sieht die Wartekette nicht (Threads „Blocked“ ohne Objekt) — Grenze notiert.
  - **Schritt 1 — Wartekette ohne Speicherabbild (zuerst, kein Datenschutzproblem):** Wait Chain Traversal
    (`OpenThreadWaitChainSession` / `GetThreadWaitChain`) für den Prozess eines hängenden Dienstes: worauf jeder
    Thread wartet (Sperre, Mutex, ALPC, COM, ein anderer Prozess), mit Besitzer-Thread/-Prozess. Ein Zyklus ist ein
    **bewiesener Deadlock** (`svc.timeout` bzw. neue Regel `svc.deadlock`, Proven). Ausgelöst, wenn ein Dienst länger als
    das SCM-Zeitlimit START_PENDING ist (B5-Regel) oder auf Anfrage. Evidenz `wct:<pid>:<tid>`.
  - [x] Schritt 2a erledigt 2026-10-18 (Agent 0.3.16–0.3.18) — die Absturzstelle OHNE Speicherabbild: Modul + Offset aus
    Ereignis 1000, PDB-Kennung aus dem PE-Kopf (CodeView), PDB vom Microsoft-Symbolserver in einen Cache, Funktion über
    Windows' eigene dbghelp.dll (`SymFromAddr`); für .NET Ausnahme + erster verwalteter Frame aus Ereignis 1026. Auf
    bossman-wintest: „.NET exception in KERNELBASE!RaiseException+0x6C; unhandled System.InvalidOperationException … at
    ProbeService.<>c.<OnStart>b__6_0()“. Gemessen und berücksichtigt: das FileVersion-Textfeld von Windows-Binärdateien ist
    veraltet (Build/Revision aus der numerischen Version); Application-Ereignisse nur noch nach Anbieter und nur, wenn sie
    das Image nennen (vorher 40–92 meist fremde Evidenzen je Diagnose).
  - [x] Schritt 2b erledigt 2026-10-18 (Agent 0.3.20): ein Hänger OHNE Sperrenbesitzer in einem .NET-Prozess wird als
    gemessene Grenze der Wartekette benannt (Lücke: „managed wait — Mutex.WaitOne/Monitor, WCT folgt dem nicht; ein
    managed Stack-Dump wäre nötig"). .NET-Erkennung über die `dotnet-diagnostic-<pid>`-Pipe (ein Single-File-Build lädt
    coreclr aus dem Speicher, nicht als Modul — gemessen). Auf bossman-wintest: `hang` → Lücke, `deadlock` → ohne.
    Ein echter Managed-Stack-Dump (dotnet-stack/ClrMD) bleibt ein eigener, späterer Schritt — der Nutzen über die
    benannte Grenze hinaus ist schmal.
  - **Schritt 2 — Minidump bei Absturz und Hänger:** Absturz über WER LocalDumps (je Dienst-Image, write-gated, mit
    Rückweg), Hänger über `MiniDumpWriteDump` (nur Thread-Stapel, kein Voll-Abbild). **Ausgewertet auf dem Host**
    (`cdb.exe !analyze -v` / Stapel aller Threads) — an Bossman und das Modell gehen nur die herausgezogenen Fakten
    (Ausnahmecode, Modul+Offset+Funktion, Stapel als Text), nie das Abbild selbst: es kann Passwörter, Tokens, Kundendaten
    enthalten. Abbild danach gelöscht, außer auf ausdrückliche Freigabe; Größenbegrenzung. Evidenz
    `dump:<id>:thread:<n>:frame:<k>`.
  - **Symbole statt Quellcode:** Funktionsnamen aus Microsofts öffentlichem Symbolserver (und den PDBs eigener
    Software); ohne Symbole bleibt Modul+Offset stehen — benannt, nicht geraten.
  - **Dekompilieren nur gezielt und nur wo erlaubt:** steht der entscheidende Frame in eigener/lizenzrechtlich
    freigegebener Software ohne Symbole, wird genau diese Funktion dekompiliert (Ghidra) und von der KI gedeutet — als
    **Likely**, nie Proven. Microsoft-Komponenten werden nicht dekompiliert.
  - **KI-Erklärung:** derselbe Prüfmechanismus wie B11 — jeder Satz zitiert Frames/Warteketten-Einträge; ein
    Funktionsname, eine Adresse oder ein Thread, der nicht in der zitierten Evidenz steht, wird „nicht belegt“ markiert.
  - [x] Linux-Hänger erledigt 2026-10-18 (Agent 0.57.94): eine Unit länger als 30 s in `activating` → `svc.timeout`
    Likely mit Zustand und Kernel-Wartestelle (`wchan`) jedes Threads aus `/proc/<MainPID>/task/*` als Evidenz
    `proc:<pid>:<tid>`. Linux-Probe 30/30 (Debian + AlmaLinux: „threads wait in the kernel in hrtimer_nanosleep“).
  - [x] Linux-Absturzstelle erledigt 2026-10-18 (Nutzer: Kernelzeile + debuginfod; Agent 0.57.96): OHNE Coredump —
    `collectCrash` liest die Kernel-Fault-Zeile (dmesg bzw. journalctl -k), `Symbolize` rechnet ip→ELF-Adresse über
    das ausführbare PT_LOAD-Segment und findet die Funktion (lokale Debug-Datei, sonst debuginfod per Build-ID, sonst
    die Symboltabelle des Moduls, zuletzt die exportierten Symbole — als solche benannt). Evidenz `ksym:<modul>:<addr>`.
    Auf echtem Pod bewiesen (statischer Crasher): „segfault at 0x10 in yoloman-crasher!crashy“. Gemessen: das neuere
    Kernel-Format ist `modul[<offset>,base+size]` mit „likely on CPU …“-Anhang (Parser angepasst).
  - **Linux-Gegenstück:** systemd-coredump (`coredumpctl info`, Stapel mit debuginfod-Symbolen) für `svc.crash`, und für
    Hänger der Kernel-Stack/`wchan` der Threads aus `/proc/<pid>/task/*/` — gleicher Vertrag, gleiche Belegpflicht.
  - Fertig: auf bossman-wintest mit dem ProbeService (eigener Code, Quellcode und PDB vorhanden) — `--mode=hang` liefert
    die Wartekette des hängenden OnStart, ein neuer Modus `--mode=deadlock` einen bewiesenen Deadlock, `--mode=crash`
    einen Minidump mit aufgelöster Funktion (`ProbeService.OnStart`-Thread) und Ausnahme; das Abbild verlässt den Host
    nicht (geprüft); Erklärung ohne „nicht belegt“. Linux: ein abstürzender Pod-Dienst mit Coredump-Stapel.

Danach (eigener Plan): Agent-Ringpuffer mit dauerhafter ETW-Sitzung (vergangene Vorfälle), dann Anmeldung, Netzwerk,
Updates; Shellvis-Anbindung über den Broker.

## Kritische Dateien

`configs/schemas/diagnosis.schema.json` (neu), `configs/diagnosis_rules.json` (neu), `internal/diagnosis/*` (neu),
`internal/modules/journal.go`, `internal/modules/service_diagnose.go` (neu), `internal/server/modules.go`,
`windows-agent/AgenticMcp.Agent.Diagnosis/*` (neu), `windows-agent/AgenticMcp.Agent.Windows/Diagnosis/*` (neu),
`windows-agent/AgenticMcp.Agent.Host/Program.cs`, `windows-agent/AgenticMcp.Agent.Tests/ContractTests.cs`,
`bossman/bossman/services/{diagnosis,diagnosis_export,diagnosis_explain,proposals}.py`, `bossman/bossman/mcp/server.py`,
`bossman/bossman/services/ops_guide.py`, `bossman/bossman/tools/package_e2e_bossman.py`, `configs/mmc_snapins.json`.

## Verifikation

1. Vertrag: `pytest bossman/tests/test_diagnosis_contract.py`, `go test ./internal/diagnosis/...`,
   `dotnet test windows-agent/AgenticMcp.Agent.Tests` — alle drei gegen dieselben Goldens.
2. Linux: `diagnosis_probe_linux.py` in beiden systemd-Pod-Images; jede kaputte Unit → erwartete `rule_id` und
   Gewissheit; Gegenprobe gegen `SHIPPED_CAUSES`.
3. Windows: `windows-agent/probes/diagnosis-probes.ps1` auf bossman-wintest legt `yoloman-probe-*`-Dienste mit
   `sc.exe` an (fehlendes Image, Pfad mit Leerzeichen, fehlende/deaktivierte Abhängigkeit, deaktiviert, Konto ohne
   Dienstanmelderecht, deaktiviertes Konto, falsches Passwort, `icacls /deny` auf dem Image, Nicht-Dienst-Exe →
   1053, ProbeService exit/crash/hang), ruft `POST /api/v1/tools/service_diagnose`, prüft `rule_id`/Gewissheit/
   Evidence-IDs, räumt im `finally` ab; Ergebnis gegen die Ereignisanzeige gegengelesen.
4. Bossman: `diagnose_service` per MCP für einen Windows- und einen Linux-Host; Exporte (Checkmk-Zeile,
   GELF, `ansible-lint`, DSC); Remedy-Vorschlag ohne Agent-Aufruf; Playwright für das Snap-in.
5. Volle Suiten bleiben grün (pytest, go test, dotnet test).

## Offene Punkte (im Verlauf entscheiden, je mit Beleg)

- ~~DSC v3: native `Microsoft.Windows/Service`-Ressource vorhanden?~~ Ja, seit DSC 3.2 (`startType` Automatic|AutomaticDelayedStart|Manual|Disabled; Set nur für eingebaute Konten als `logonAccount`).
- Reliability-Records auf Server 2022 aktiv? (B7)
- Domänen-/gMSA-Konten ohne DC-Zugriff bleiben `Unknown` mit benanntem Grund (B6).
