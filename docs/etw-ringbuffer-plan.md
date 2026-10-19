# ETW-Ringpuffer — „was ist VOR dem Vorfall passiert?"

## Kontext

Die erklärbare Diagnose (`docs/diagnosis-plan.md`) liest den **aktuellen** Zustand: *warum läuft dieser Dienst
jetzt nicht*. Transiente Vorfälle sind dann schon vorbei — ein Dienst, der um 3 Uhr abstürzte und neu startete; ein
Hänger, der sich löste; eine `.NET`-Ausnahme kurz vor dem Exit. Das Windows-Ereignisprotokoll hält das oft nicht fein
genug (kein Prozess-Exit-Code je PID) oder nicht lange genug vor. Dieses Epic gibt dem Agenten einen **dauerhaften,
beschränkten Ringpuffer der jüngsten Vorfälle**, aus dem die Diagnose eine *vergangene* Ursache belegen kann.

Nutzer-Entscheidung 2026-10-18: vollständig umsetzen (E0→E5).

## Ansatz

Eine dauerhafte **Echtzeit-ETW-Sitzung** über `Microsoft.Diagnostics.Tracing.TraceEvent`, konsumiert auf einem
eigenen Thread im Agenten-Dienst (läuft als SYSTEM → Kernel-Provider erlaubt). Provider: **Kernel-Process**
(Prozess-Start/-Exit inkl. Exit-Code, Image-Load) und **Microsoft-Windows-DotNETRuntime** (ExceptionThrown).
Gespeichert wird **nur ein kleiner Datensatz je Ereignis** (Zeit, PID, Image, Art, Exit-Code/Ausnahmetyp) — **keine
Payloads, kein Speicher, kein Dump**; fester Ring (Größe + Höchstalter). Datenschutz zuerst: nur Metadaten.

## Vertrag (unverändert zu B0 der Diagnose)

Jeder Ring-Eintrag wird Evidenz mit stabiler ID (`etw:proc-exit:<pid>:<ts>`, `etw:exception:<pid>:<ts>`); Gewissheit
nach denselben Regeln (ein vergangener Vorfall ist **Likely**, nie Proven — er beschreibt eine frühere Invocation,
nicht den gegenwärtigen Zustand); nichts wird erfunden; die KI erklärt nur, mit Belegprüfung (B11). Die Diagnose zieht
beim Befragen eines Dienstes die jüngsten Ring-Einträge zu dessen Image/PID als **Zeitachse + Vorgeschichte** heran.

Neue Regel `svc.recent_incident` (Likely, beide Plattformen): „Dienst lief, beendete sich um X mit Code Y / warf
Ausnahme Z" — mit Ring-Einträgen als Evidenz.

## Blöcke (jeder einzeln getestet, Commit + CHANGELOG mit Beleg; kein Push ohne Freigabe)

- [x] **E0 — Ring-Modell + Vertrag** erledigt 2026-10-18 (commit 86d46f58f): `Incident`-Datensatz + beschränkter,
  thread-sicherer `IncidentRing` (feste Kapazität + Höchstalter, Add/Recent mit Filter) im Projekt
  `AgenticMcp.Agent.Diagnosis` (net10.0, ohne Win32 → unter Linux testbar). Abbildung `Incident → Evidence` (stabile ID
  `<source>:<kind>:<pid>:<unix-ms>`); Regel `svc.recent_incident` (Likely, order 950) in `configs/diagnosis_rules.json`
  + beiden Kopien, in Python/Go/C# konsistent. 26 C#-Tests (Ring-Verdrängung nach Größe/Alter, ID-Stabilität,
  ebpf-Source, nebenläufige Adds). Image-Match über Basename auf `/` UND `\` (nicht `Path.GetFileName`, das auf dem
  Linux-Testhost Windows-Pfade nicht zerlegt).
- [x] **E1 — ETW-Session-Collector** erledigt 2026-10-18 (Agent 0.3.27): `EtwIncidentCollector` (TraceEvent 3.1.16,
  Kernel-Process + CLR-Exception) in `AgenticMcp.Agent.Windows`, eigener Consumer-Thread, sauberes Start/Stop (stoppt
  eine verwaiste Vorgänger-Session), Filter auf Exit≠0 (ProcessExit) bzw. NTSTATUS-Fehler ≥0xC0000000 (ImageCrash) und
  managed Exceptions. Nur SYSTEM; scheitert die Session, wird der Grund geloggt und der Agent läuft weiter. Cross-build
  win-x64 sauber. Live-Beleg zusammen mit E3 (gemeinsamer Lese-Weg).
- [x] **E2 — Persistenz über Neustart** erledigt 2026-10-18 (Agent 0.3.29): `IncidentRing.SaveTo/LoadFrom` (JSON,
  atomar via temp+move, Höchstzahl 512, alters-/kapazitäts-begrenzt beim Laden; fehlende/korrupte Datei → leer, kein
  Absturz; `[JsonIgnore]` auf der berechneten EvidenceId). Der Collector lädt beim Start aus
  `<stateDir>\incident-ring.json`, flusht per 1-Minuten-Timer und — via `ApplicationStopping` (UseWindowsService macht
  den Dienst-Stopp graceful) — bei jedem sauberen Stopp. 3 Unit-Tests (Round-Trip, Alters-Drop beim Laden, fehlend/
  korrupt). **Live auf bossman-wintest:** Crash auf 0.3.28 → Deploy 0.3.29 (sauberer Stopp flusht, neuer Agent lädt) →
  die Diagnose zeigt `svc.recent_incident` WEITER, obwohl die neue ETW-Session den Crash nie sah; Ring-Datei 40 KB.
- [x] **E3 — Diagnose-Anbindung** erledigt 2026-10-18: `WinServiceSnapshot.RecentIncidents` (aus dem Ring, gefiltert
  nach Image — ein vergangener Absturz lief unter anderer PID), `WindowsRules` emittiert `svc.recent_incident` (Likely)
  mit den Vorfällen als Evidenz, auf dem running- UND dem failed-Pfad (nach PrecedeAll, damit kein Precedent anhängt);
  `ServiceDiagnoseModule(incidentRing)`. 3 Unit-Tests (auf Linux). **Live auf bossman-wintest** (ProbeService
  `--mode=crash`): die Diagnose trägt `svc.crash/Proven` (SCM) UND `svc.recent_incident/Likely` (ETW-Ring) mit ZWEI
  erfassten Vorfällen für ProbeService.exe — `etw:exception` (System.InvalidOperationException, CLR-Provider) und
  `etw:image-crash` (Exit 0xE0434352, Kernel-Provider), beide `source: etw-incident-ring`. Reihenfolge: E3 vor E2
  gebaut, weil E1s Live-Nachweis an E3s Lese-Weg hängt (E2 Persistenz folgt als Nächstes).
- [x] **E4 — Linux-Gegenstück** erledigt 2026-10-18 (Code + unit-getestet + live): Go-`Incident`-Typ (Spiegel
  von C#, Source „ebpf"), `SystemdSnapshot.RecentIncidents`, `addRecentIncidents` in `systemd_rules` (Likely, nach
  Precede, running+failed), `ServiceDiagnose.Incidents`-Quelle (nach kernel-comm = exec-Basename auf 15 Zeichen gekürzt
  gefiltert). Der vorhandene eBPF-Collector wird angezapft: `server.RecentIncidents(collector)` bildet
  `RecentOOMKills`+`RecentSignals` (nur abnormale: SEGV/ABRT/KILL/QUIT, NICHT TERM/INT) auf Incidents ab — **read-only,
  kein Timescale-Write** (Nutzer-Hinweis: eBPF-Metriken hatten die DB aufgebläht), die Vorfälle erscheinen nur on-demand
  im Diagnose-Dokument. In `cmd/agentic-mcpd/main.go` verdrahtet. Go-Tests grün (Regel-Emission, comm-Filter/-Kürzung,
  Mapping). **Live auf echtem Kernel** (root via marvin, build-getaggter `internal/server/ebpf_live_test.go`,
  `-tags ebpflive`): ein echtes `SIGSEGV` an einen `sleep`-Prozess wurde vom eBPF-Collector gefangen und von
  `server.RecentIncidents` als Incident `ebpf:fatal-signal:<pid>:…` (Image „sleep", Detail „SIGSEGV", Source „ebpf")
  geliefert — der reale Fang→Incident-Pfad bewiesen; die Incident→`svc.recent_incident`-Emission ist unit-getestet.
- [ ] **E5 — Bossman/UI.** Vorfälle im Diagnose-Panel als Zeitachse „Letzte Vorfälle"; optional per GELF exportierbar
  (Wiederverwendung des Senders aus B9). Fertig: Playwright-Szenario grün, Konsistenz-Crawler ohne neuen Verstoß.

## Ausdrücklich NICHT im Scope

Kein ETW-zu-Platte-Logging-Produkt, kein Ersatz fürs Ereignisprotokoll, keine Speicherabbilder, keine unbegrenzte
Aufzeichnung. Nur Metadaten, fester Ring.

## Kritische Dateien

`windows-agent/AgenticMcp.Agent.Diagnosis/{Incident,IncidentRing}.cs` (neu),
`windows-agent/AgenticMcp.Agent.Windows/Diagnosis/EtwIncidentCollector.cs` (neu),
`windows-agent/AgenticMcp.Agent.Windows/*.csproj` (TraceEvent-Paket),
`configs/diagnosis_rules.json` + die beiden Kopien (`internal/diagnosis/rules.json`,
`windows-agent/AgenticMcp.Agent.Diagnosis/rules.json`), `internal/ebpf/*` (E4),
`bossman-ui/.../features/diagnosis/*` (E5).
