# Closed-Loop Remediation — Umsetzungsplan

> Self-healing **mit Bremse**: automatische Reparatur *plus* Nachkontrolle *plus*
> Guardrails, statt nur Alarm. Baut auf dem vorhandenen (bewusst offenen)
> Remediation-Gerüst auf und schließt den Regelkreis.

## 1. Ist-Zustand (was schon existiert)

Der Kreis ist heute **offen**: erkennen → vorschlagen → *Mensch* wendet an. Konkret:

- **Detect** — `services/poller.py` stempelt `_notify_event == "problem"`, wenn ein
  Service hart CRIT/WARN wird; ruft danach `remediation.collect_and_propose(touched)`.
- **Policy** — `RemediationPolicy` (`db/models.py`): `match_service_name` + `scope_type`
  (global|ou|group|host) + `conditions` (rule_conditions: host_tags/labels/criticality/…)
  → ein `runbook_name` + `params`, `max_per_hour`, `mode: auto|propose`, `enabled`.
- **Propose** — `remediation.propose_for_service` legt eine **pending** `RemediationRun`
  an; Doku sagt ausdrücklich *"Execution NEVER happens automatically — only from an
  Apply"*. `apply_run` führt einen proposed Run aus (`runbook_exec.execute_runbook`).
- **Governance** — `ChangeProposal` (`api/proposals.py`): `kind=config|runbook`, `payload`,
  `preview` (Dry-run-Diff/Recap), `status pending|approved|rejected|applied|failed`,
  `requested_by="ai:…"`, approve/reject-Endpoints. Für Config/Resource-Änderungen.
- **Bausteine drumherum** — `nl_policy.py` (NL→Policy), `whatif.py`, `blast_radius.py`,
  Notification-Kanäle + Eskalation, Resource-Protokoll `apply/rollback/generations`
  (`services/resources/base.py`), RAG (`knowledge_index` mit problems/**changes**/events,
  `/api/v1/ask`), `recheck-now` (sofortige Neubewertung eines Checks).

**Fazit:** Detect, Plan, Gate (approve), Act, Rollback-Fähigkeit, Eskalation, Diagnose
sind einzeln vorhanden. Es fehlt das **Zusammenschließen** zu einem verifizierten,
nachverfolgbaren Vorgang.

## 2. Die Lücke — was „closed" braucht

1. **Verify** — nach dem Fix den auslösenden Check gezielt neu bewerten und das
   Ergebnis am Vorgang festmachen. *(Kernstück, existiert nicht)*
2. **Rollback/Escalate bei Misserfolg** — half es nicht: zurückrollen (wo möglich)
   und/oder eskalieren, statt still zu scheitern.
3. **Autonomie-Guardrails** — pro Policy/Scope ein *Autonomiegrad* statt binär
   `auto|propose`, mit Gate-Bedingungen (nur non-prod, nur bestimmte Fix-Klassen,
   Blast-Radius-Cap, Kill-Switch, Zeitfenster).
4. **Lifecycle-Entität** — ein Vorgang mit Zustandsautomat (detect→…→verify→
   resolved|rolled_back|escalated), der alles zusammenhält (Audit + UI).
5. **Diagnose-Anreicherung (optional)** — die RAG-Ursache (inkl. „Fehler ↔ kürzliche
   Änderung") an den Vorschlag hängen, damit Mensch/KI den Kontext sehen.

## 3. Datenmodell (minimale Migration)

`RemediationRun` von einer Attempt-Zeile zur **Vorgangs-Lifecycle-Zeile** erweitern
(eine Migration, additive Spalten):

| Spalte (neu) | Zweck |
|---|---|
| `phase` | `detected \| proposed \| approved \| applying \| verifying \| resolved \| failed \| rolled_back \| escalated` |
| `trigger_service_id` / `trigger_state` | welcher Check den Vorgang auslöste + Ausgangszustand |
| `applied_at`, `apply_result` (JSONB) | was ausgeführt wurde |
| `verify_after_s`, `verified_at`, `verify_state`, `verify_ok` | Nachkontrolle |
| `outcome` (Text) | Kurzfazit: recovered / no_change / rolled_back / escalated |
| `generation_ref` (JSONB) | für Resource-Fixes: die Generation, auf die zurückgerollt werden kann |

`RemediationPolicy` um die **Guardrails** erweitern:

| Spalte (neu) | Default | Zweck |
|---|---|---|
| `autonomy` | `propose` | `propose \| auto_verify \| auto` (ersetzt `mode` semantisch) |
| `verify` | `true` | nach Apply verifizieren |
| `verify_after_s` | `60` | Wartezeit vor Verify (bzw. sofortiger recheck) |
| `rollback_on_fail` | `true` | bei fehlgeschlagenem Verify zurückrollen (wo möglich) |
| `escalate_channel` | null | Notification-Kanal bei Misserfolg |
| `require_approval` | `true` | Gate vor Apply (auch bei auto_verify optional) |
| `max_blast_radius` | null | Cap: max. betroffene Hosts (via `blast_radius`) |

## 4. Der Regelkreis als Zustandsautomat

```
 detected ──policy match?──► proposed ──gate (autonomy/guardrails)──►
   approved/auto ──► applying ──► verifying ──►
      recovered ─► resolved            (Loop geschlossen, Audit + info-Notify)
      not recovered ─► rollback_on_fail? ─► rolled_back ─► escalated
                        else ───────────────────────────► escalated
```

- **gate** entscheidet den Übergang proposed→applying:
  `autonomy==propose` → warte auf menschliches Approve;
  `autonomy==auto_verify/auto` **und** alle Guardrails erfüllt → automatisch.
- **verifying**: Trigger-Check per `recheck-now` neu bewerten, `verify_state`
  vergleichen. OK → `resolved`; sonst → rollback/escalate.
- **Anti-Oszillation**: `max_per_hour` + Backoff + „nach N Fehlversuchen nur noch
  eskalieren" (kein endloses Retry).

## 5. Guardrails (das Herz)

Reihenfolge der Gates vor einer automatischen Ausführung:
1. **Kill-Switch** — globaler Schalter (Settings) + `enabled` der Policy.
2. **Autonomie** — `autonomy != propose`.
3. **Scope + conditions** — `rule_conditions` (z. B. `criticality != prod`,
   `host_tags.env == test`), wie heute schon ausgewertet.
4. **Rate-Limit** — `max_per_hour` (vorhanden) + Backoff.
5. **Blast-Radius-Cap** — `blast_radius`/`whatif` unter `max_blast_radius`.
6. **Zeitfenster** (optional, später) — nur in Wartungsfenstern.

Default-Haltung: **alles `propose`** (heutiges Verhalten). Autonomie ist explizites
Opt-in pro Policy/Scope — zuerst nur Test-/Low-Criticality-Hosts, idealerweise gegen
**Rehearsal-Klone** statt Prod.

## 6. Verify · Rollback · Escalate

- **Verify** — neuer Schritt `remediation.verify_run(run)`: `recheck-now` für den
  Trigger-Check auf dem Host, Service-State erneut lesen, `verify_ok` setzen.
  Läuft als throttled Poller-Schritt (wie `agent_release.maybe_refresh`), der Runs
  in `phase=verifying` abholt, deren `verify_after_s` abgelaufen ist.
- **Rollback** — Resource-Fixes: `resources/base.rollback` auf `generation_ref`.
  Runbook-Fixes sind i. d. R. nicht auto-reversibel → dann direkt eskalieren
  (`outcome=no_change`), kein blindes Zurückrollen.
- **Escalate** — Notification-Kanal (vorhandene Eskalations-Engine) + `phase=escalated`;
  der Mensch übernimmt. Das ist der bewusste „Bremsweg".

## 7. Mapping — vorhanden vs. neu

| Stufe | Status | Wo |
|---|---|---|
| Detect | ✅ vorhanden | poller `problem`-Marker → `collect_and_propose` |
| Diagnose | ◻ teils | RAG `/ask` + changes/events-Karten → an Proposal hängen (neu) |
| Plan/Fix | ✅ vorhanden | RemediationPolicy→Runbook; ChangeProposal (Dry-run) |
| Gate/Approve | ◻ teils | approve/reject da; **Autonomie + Blast-Cap + Kill-Switch neu** |
| Act | ✅ vorhanden | `apply_run` / ChangeProposal-Apply, dry-run |
| **Verify** | ❌ **neu** | `verify_run` + recheck-now + Lifecycle-Felder |
| Rollback | ◻ teils | Resource-`rollback`/generations vorhanden → verdrahten |
| Escalate | ◻ teils | Notification/Eskalation vorhanden → an fehlgeschlagenen Verify hängen |
| Lifecycle-Entität | ❌ **neu** | RemediationRun-Erweiterung + Zustandsautomat |

## 8. Phasen (safety-first)

- **Phase 1 — Loop schließen ohne Autonomie.** Lifecycle-Felder + `verify_run` +
  Escalate-on-fail auf den **bestehenden** propose→apply-Fluss. Jede *manuell*
  angewandte Remediation wird jetzt automatisch verifiziert, das Ergebnis
  protokolliert, bei Misserfolg eskaliert. Hoher Wert, null Autonomie-Risiko.
- **Phase 2 — Autonomie + Guardrails.** `autonomy=auto_verify` opt-in pro Policy/Scope
  (zuerst non-prod), Blast-Cap, Kill-Switch, Auto-Rollback (nutzt Phase-1-Verify).
- **Phase 3 — Diagnose + Sicht.** RAG-Ursache (inkl. Änderungs-Korrelation) am
  Vorschlag; Incident-/Remediation-Dashboard; „gegen Rehearsal-Klon zuerst".

## 9. Risiken / offene Fragen

- **Flapping / falsches „recovered"** — Verify erst nach Stabilisierung (`verify_after_s`)
  + „hard state", nicht beim ersten OK.
- **Nicht-reversible Fixes** — Runbook-Fixes nicht blind zurückrollen; nur Resource-
  Generationen sind sauber reversibel. Sonst eskalieren.
- **Oszillation** — `max_per_hour` + Backoff + Aufgeben nach N.
- **Prod-Sicherheit** — Default propose-only; Autonomie nur explizit, scoped, am besten
  über die Rehearsal-Plane.
- **Verify-Kosten** — recheck-now pro Vorgang; throttled im Poller bündeln.
