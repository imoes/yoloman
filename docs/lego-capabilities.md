# Lego-Infrastruktur: selbstdokumentierende Templates + deterministischer Capability-Matcher

> Status: **UMGESETZT & live** (alle 6 Phasen implementiert, deployed, verifiziert). Dieses Dokument
> bewahrt den ursprünglichen Plan als Projekt-Doku. Laufende Details siehe Memory `project-lego-capabilities`.

## Kontext

Ziel: einen Server definieren (oder eine Rolle wählen), und das System **rechnet aus**, was er braucht,
wer im Inventar das liefert, und schlägt Verbindungen samt Konfiguration vor — oder schlägt vor, einen
neuen Server mit passender Rolle anzulegen. Komponenten wie Lego-Steine zusammenklickbar; die KI kann
dasselbe, aber **der Kern ist pure Logik und braucht zur Laufzeit keine KI**.

Dafür muss in den Templates stehen, **welche Felder eine Verbindung tragen** (`db_host`, `db_port`) und
**welche Backends möglich sind** (PostgreSQL *oder* MySQL). Ausgangslage (gemessen): 3.219 Templates,
Qualify-Pipeline 9.559 Pakete; 7,6 % kaputt (mit Ansible-Filtersatz gemessen); Schemas 99,97 % flach;
Provider-Seite deklarierte nichts.

Modellvergleich (Selbstkorrektur + Render-Tor, 10 Templates inkl. der kaputten): **Qwen3.6-35B 10/10**
> laguna-s-2.1 9/10 > qwen79b 9/10. Ein-Schuss ohne Schleife: 3/10 — die exakte Fehler-Rückkopplung ist
der Hebel.

## Phase 1 — Qualify-Pipeline mit Enrich-Optionen (der Batch) — UMGESETZT
Anreicherung in `bossman/scripts/qualify_packages.py` eingebaut (`PIPELINE_VERSION="v6-enriched"`, Modell
`qwen35b`). Pro Paket **ein** LLM-Aufruf → zwei Artefakte: angereichertes `template.j2` (selbstdokumentierend,
Ansible-kompatibel, jede Variable `| default(<Schema-Default>)`, Schema-Beschreibung als Kommentar) **und**
`capabilities.json`. **Fünf deterministische Tore** (in `bossman/scripts/enrich_gates.py`): (1) Contract
(`batch_verify.verify_template`), (2) gonja-Render (`cmd/render-check`), (3) echtes Ansible (leerer Kontext),
(4) Feld-Existenz, (5) Vokabular. Bei Fehlschlag Selbstkorrektur ≤3 Runden. Dienst
`agentic-qualify-packages` (concurrency zunächst 3, dann auf 1 zurückgesetzt — der Endpunkt serialisiert).
Deterministischer Schema-Normalizer + batch_verify-Fixes, damit vorbestehende Schema-Drift den Enrich nicht
blockiert.

## Phase 2 — Ansible-Parität im Go-Agenten — UMGESETZT
`internal/modules/ansible_filters.go`: 24 Ansible-eigene Filter in gonja registriert (`to_json`, `ternary`,
`dict2items`, `regex_replace`, `b64encode`, …); `password_hash`/`ipaddr(arg)` verweigern loud. Korpus-
Bruchquote 64→51. Tests pro Filter.

## Phase 3 — Der Vertrag (capabilities.json) + Vokabular — UMGESETZT
`configs/capability_vocabulary.json` (21 Capabilities, 79 Backends, Aliasse mysql↔mariadb / redis→valkey/
keydb). Sidecar `configs/config_templates/<name>/capabilities.json` (provides/requires/peer_injection).
Provider tragen unpräfigierte Felder + `default_port`; Consumer präfigierte Feld-Maps.

## Phase 4 — Inventar in der DB (deterministisch) — UMGESETZT & LIVE
Tabelle `host_capabilities` (Migration `a1c9e4f2b7d3`); `services/capabilities.py` leitet aus
`Agent.facts["installed_packages"] × package_catalog.json × capabilities.json` die Host-Capabilities ab,
reconciled pro Host (source derived|explicit), stündlicher `capabilities_loop`. Live verifiziert: 4
chrony-Hosts → 4 `provide ntp:chrony`.

## Phase 5 — Matcher (pure Logik) + drei Oberflächen — UMGESETZT
`services/capabilities.py`: `open_requirements` / `find_providers` (alias-bewusst) / `roles_providing` /
`propose_wiring` (beide Seiten inkl. NFS-Peer-Injection). Eine Logik, drei Oberflächen: **REST**
(`api/capabilities.py`: /agents/{id}/capabilities, /capabilities/providers, /capabilities/match, live
getestet), **MCP-Tool** + **Chat-Tool** (`capability_match`).

## Phase 6 — Blueprint-Editor auf Rollen-Ebene — UMGESETZT
`compose-model.ts`/`compose-wiring.ts` backend-bewusst (Postgres wird für einen mysql/mariadb-Consumer
abgelehnt, MariaDB per Alias akzeptiert; Fallback auf Archetyp-Tokens); `config-templates`-Endpunkt liefert
`capabilities.json`; `core/services/capabilities.service.ts`; „offene Anforderungen" listet Inventar-Anbieter
bzw. Kandidaten-Rollen. Wiring-Regeln 7/7 (headless verifiziert), Build grün.

## Kritische Dateien
`bossman/scripts/qualify_packages.py` (Enrich), `bossman/scripts/enrich_gates.py` (Tore + Prompts),
`bossman/scripts/enrich_templates_pilot.py` (Prüfstand), `internal/modules/ansible_filters.go`,
`cmd/render-check/`, `configs/capability_vocabulary.json`, `configs/config_templates/*/capabilities.json`,
`bossman/bossman/services/capabilities.py`, `bossman/bossman/db/models.py` (`host_capabilities`) + alembic
`a1c9e4f2b7d3`, `bossman/bossman/api/capabilities.py`, `mcp/server.py` + `services/chat_tools.py`,
`bossman-ui/.../blueprint/compose-{model,wiring}.ts` + `core/services/capabilities.service.ts`.

## Verifikation (erfüllt)
Pilot 10/10; `go test ./internal/modules/` (Filter) grün; Matcher-Tests (pure + DB); REST live gegen echte
ntp-Provider; Editor-Wiring backend-bewusst (7/7). Der Enrich-Batch füllt `capabilities.json` fortlaufend
über den ganzen Katalog (nur ~1 % Schemas überspringen wegen vorbestehender Defekte, sicher protokolliert).
