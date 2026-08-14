# Logik-Audit Frontend + Backend — Aufgabenstellung

> Auftrag: das gesamte System gegen die Regeln der formalen Logik prüfen und
> überarbeiten (Skill `/logik`, Kurzfassung in `/home/mutkluge/CLAUDE.md`).
> Dieses Dokument definiert **die Aufgabe** — nicht die Befunde. Befunde und
> beschlossene Änderungen werden pro Bereich unten angehängt.

## 1. Zweck

Nicht Geschmack, nicht Kosmetik: geprüft werden die **Fehlerklassen, die
Fehlbedienung verursachen**. Ein Logikfehler ist etwas, das man beweisen kann —
zwei Namen für ein Ding, zwei Ansichten mit widersprüchlichem Zustand, ein
Zustand ohne Namen, eine Anzeige ohne Begründung. Ästhetik (Apple-HIG) ist die
*Darstellungsseite* derselben Regeln und wird zusammen mit ihnen bewertet, nie
statt ihnen.

## 2. Prüfumfang (beides, nicht nur UI)

Ein Logikfehler kann in jeder Schicht entstehen und muss dort behoben werden, wo
er entsteht — deshalb wird **Frontend und Backend gemeinsam** geprüft:

| Schicht | Was geprüft wird |
|---|---|
| **Datenmodell** (`bossman/db/models.py`) | Ist der Zustandsraum erschöpfend? Sind verbotene Kombinationen durch Constraints unmöglich (nicht erst im UI)? Heißt jedes Feld eindeutig? |
| **Services** (`bossman/services/*`) | Ist die Fachlogik widerspruchsfrei? Wird jede Verweigerung mit **Grund** zurückgegeben? Eine Quelle der Wahrheit pro Tatsache? |
| **API** (`bossman/api/*`) | Liefert sie alle Zustände, die das Modell kennt? Heißen Felder wie im Modell? Sind Fehlerpfade so vollständig wie Erfolgspfade? |
| **UI** (`bossman-ui/src/app/**`) | Zeigt sie jeden Zustand, den die API liefert? Ein Begriff pro Ding über alle Screens? Kommt man von jedem Wert zur Ursache? Unmögliche Aktionen ausgegraut statt Fehlermeldung? |
| **Agent** (`internal/**`) | Bedeutet ein Begriff dasselbe wie serverseitig (keine Äquivokation über Schichten)? |

**Besonders zu prüfende Kopplung:** Zustände, die das Backend kennt, aber das
Frontend nie zeigt — das ist der häufigste und gefährlichste Fall, weil das
System korrekt ist und der Bediener trotzdem falsch handelt.

## 3. Methode

Pro Bereich in dieser Reihenfolge:

1. **Begriffe auflisten** — jede Entität mit ihren Namen in DB / Service / API /
   UI in einer Tabelle. Die meisten Logikfehler sind Namensfehler und fallen hier
   sofort auf.
2. **Zustandsraum aufschreiben** — alle Werte, die ein Objekt annehmen kann, und
   für jeden: wird er *gespeichert*, *ausgeliefert*, *angezeigt*, *behandelbar*?
   Eine Lücke in dieser Kette ist ein Befund.
3. **Die sechs Prüfblöcke** aus `/logik` mit Beleg `datei:zeile`.
4. **Befunde priorisieren**: (a) Widersprüche, (b) unklassifizierte/unsichtbare
   Zustände, (c) fehlende Begründung, (d) Redundanz, (e) Benennung.
5. **Vorschlagen, nicht heimlich umbauen** — kleinster Fix pro Befund; größere
   Umbauten als gestaffelter Plan zur Entscheidung.

## 4. Reihenfolge der Bereiche

Nach Schadenspotenzial, nicht nach Aufwand:

1. **Checks / Discovery / Service-Checks** — hier ist bereits belegt, dass das
   Backend mehr weiß als die UI zeigt (Zustand `vanished`), und es gibt zwei
   Screens für eine Aufgabe.
2. **Monitoring / Events / Alarme** — Schwellwert → Zustand → Alarm: ist die
   Begründungskette vollständig sichtbar?
3. **Config / Policy** (Regel vs. Instanz, Herkunft der Regel: global < Gruppe <
   OU < Site < Host).
4. **Desired State / Rollouts / Remediation** — Soll vs. Ist nie vermischt, jede
   automatische Aktion begründet.
5. **Storage / Disks** (frisch überarbeitet — als Referenz und Gegenprobe).
6. **Fleet / Suche / Dashboards** — Aggregation ohne unzulässige Verallgemeinerung.

## 5. Ergebnis je Bereich

- Begriffstabelle + Zustandsraum-Tabelle (die bleiben als Doku hier stehen).
- Befundliste im `/logik`-Format (Regel, Beleg, Problem, kleinster Fix).
- Entscheidung des Nutzers je Befund; danach Umsetzung mit Test und Commit.

## 6. Abnahmekriterien

Ein Bereich gilt als geprüft, wenn:

- [ ] jede Entität **einen** Namen über alle Schichten hat (oder die Übersetzung
      an genau einer Stelle liegt),
- [ ] jeder Zustand des Modells in der API **und** im UI ankommt und dort
      behandelbar ist — insbesondere „war da, ist weg",
- [ ] kein Screen einen Zustand zeigen kann, der einem anderen Screen
      widerspricht,
- [ ] jede Verweigerung und jeder auffällige Wert seinen **Grund** nennt oder
      dorthin verlinkt,
- [ ] es für jede Aufgabe **einen** Ort gibt,
- [ ] für jede tragende Annahme ein Beobachtungspunkt existiert (Anzeige oder
      Test), an dem man merken würde, dass sie falsch ist.

---

## Befunde: Bereich 1 — Checks / Discovery / Service-Checks

### Begriffstabelle

Vier verschiedene Dinge heißen im UI alle „Check" bzw. „Service":

| Ding (was es ist) | DB | API | UI |
|---|---|---|---|
| **Definition** eines Checks (Katalogeintrag) | Dateien via `checks_library` | `GET /checks` | „Checks catalog" |
| **Regel**: Check ist einem Scope zugewiesen | `CheckAssignment` | `/check-assignments` | Host▸Checks, Spalte „From" |
| **Tatsache**: Discovery hat einen Service gefunden | `DiscoveredService` (+`state`) | `GET /agents/{id}/discovered-services` | — **nirgends** |
| **Messung**: Live-Zustand OK/WARN/CRIT | `Service` | `/monitoring` | Host▸Checks, untere Tabelle |
| **Aktiver Service-Check** (HTTP/TCP/DNS) | `CheckAssignment` | `/check-assignments` | Management▸Service checks (eigener Screen) |

### Zustandsraum Discovery

| Zustand | gespeichert | ausgeliefert | angezeigt | behandelbar |
|---|---|---|---|---|
| `undecided` (Checkmks „new") | ✅ | ✅ | ❌ | teilweise (nur direkt nach einem Lauf) |
| `monitored` | ✅ | ✅ | ⚠️ nur indirekt als Zuweisung | ✅ |
| `vanished` | ✅ | ✅ | ❌ | ❌ |
| `ignored` | ✅ | ✅ | ❌ | ❌ |

### Befunde

```
[Ausgeschlossenes Drittes] Der Zustand "vanished" existiert, ist aber unsichtbar
  Beleg:   bossman/bossman/db/models.py:1098 CHECK state IN ('undecided','monitored','vanished','ignored')
           bossman/bossman/services/discovery_lifecycle.py:37-40 (die vier Zustände)
           bossman/bossman/api/checks.py:616-645 liefert counts + state je Service
           bossman-ui: 0 Treffer für "vanished" / "undecided" / "ignored";
           der Endpoint discovered-services wird nie aufgerufen
  Problem: Ein Service, der vom Host verschwindet, verschwindet auch aus der
           Ansicht — der Zustandsraum des UI ist unvollständig, und der Bediener
           erfährt nie, dass etwas fehlt (genau das, was Checkmk als "vanished"
           zeigt).
  Fix:     Im Host▸Checks-Tab eine Discovery-Sektion aus dem vorhandenen
           Endpoint: vier Zähler (neu / überwacht / verschwunden / ignoriert),
           Liste filterbar, "verschwunden" rot, mit den Aktionen, die die API
           schon kann (entfernen bzw. behalten+ignorieren). Kein neues Backend.

[Identität] Ein Wort, vier Dinge
  Beleg:   features/hosts/host-checks.component.ts:153 (<th>Check</th> = Regel)
           features/hosts/host-checks.component.ts:188 (<th>Service</th> = Messung)
           features/checks/checks-catalog.component.ts (= Definition)
  Problem: "Check" bezeichnet Definition, Regel, Fund und Messung — Äquivokation
           über vier Ebenen; man kann nicht sagen, was eine Zeile behauptet.
  Fix:     Benennung festlegen und überall gleich verwenden: Check (Definition),
           Zugewiesener Check (Regel), Gefundener Service (Tatsache),
           Service-Zustand (Messung). Je Sektion eine Zeile, die das sagt.

[Parsimonie] Zwei Orte für eine Aufgabe
  Beleg:   features/hosts/host-checks.component.ts:19-27 — der Kommentar erklärt
           selbst, dass Katalog-Browsing "nicht hier, sondern in
           Management▸Service checks" liegt ("single source of truth")
           features/hosts/management/service-checks/service-checks.component.ts:1-3
  Problem: "Einen Check zu diesem Host hinzufügen" geht an zwei Stellen, getrennt
           nach *wie* man ihn findet (Discovery vs. Katalog) — nicht nach dem, was
           der Nutzer tun will. Die Begründung im Kommentar ist eine Erklärung der
           Redundanz, keine Aufhebung.
  Fix:     Service-Checks in den Host▸Checks-Tab als Aktion "Check hinzufügen"
           falten (Dialog existiert und ist geteilt); ein Screen beantwortet
           "was wird auf diesem Host geprüft".

[Zureichender Grund] Der Zustand nennt seinen Schwellwert nicht
  Beleg:   features/hosts/host-checks.component.ts:188-196 (Service/State/Value/Metric)
  Problem: Warum ist eine Zeile WARN? Der Schwellwert, der den Zustand erzeugt
           hat, steht nicht dort und ist von dort nicht erreichbar — die Zuweisung
           oben zeigt ihre Herkunft ("From"), die Messung unten nicht.
  Fix:     Spalte "Schwelle" (warn/crit) plus Link auf die Regel, aus der sie
           kommt — dieselbe Herkunftslogik, die die Zuweisungstabelle schon hat.
```

### Beim Umsetzen zusätzlich gefunden (beide im Backend)

```
[Widerspruchsfreiheit] `remove` machte aus einem verschwundenen Service einen "neuen"
  Beleg:   bossman/bossman/api/checks.py, apply_discovery, verb == "remove"
  Problem: Die Zeile wurde pauschal auf `undecided` gesetzt. Bei state='vanished'
           behauptet das "Discovery hat ihn gefunden, unentschieden", obwohl genau
           dieser Lauf ihn nicht gefunden hat — und er wäre beim nächsten Lauf als
           "neu" wieder aufgetaucht.
  Fix:     Bei `vanished` die Zeile löschen (wie discovery_lifecycle bei
           remove_vanished_services); bei noch vorhandenem Service bleibt undecided.
  Status:  ERLEDIGT, live belegt: Vanished 1→0 und New blieb 198 (nicht 199),
           die Zeile war weg.

[Widerspruchsfreiheit] "Monitored 10" neben "No assigned checks on this host yet"
  Beleg:   bossman/bossman/api/checks.py, delete_assignment (löschte nur die
           Zuweisung); Screenshot des Checks-Tabs zeigte beide Aussagen gleichzeitig
  Problem: Die Invariante "state='monitored' ⇒ es gibt eine Zuweisung" war nicht
           gehalten: eine autodiscovered Host-Zuweisung konnte gelöscht werden,
           während die Discovery-Zeile weiter `monitored` behauptete. Zwei Ansichten
           desselben Hosts widersprachen sich.
  Fix:     delete_assignment setzt eine autodiscovered Host-Zuweisung zugehörige
           Zeile von `monitored` auf `undecided` zurück (dasselbe, was `remove` tut).
  Status:  ERLEDIGT.
```

### Rangfolge

1. ~~`vanished` sichtbar und behandelbar machen~~ — **ERLEDIGT** (Sektion
   „Discovered services" mit vier immer sichtbaren Zählern, vanished rot +
   durchgestrichen, Aktionen Remove/Ignore/Monitor/Stop; live belegt).
2. ~~Schwellwert/Begründung an der Messung~~ — **ERLEDIGT**: Spalte „Threshold"
   zeigt die Regel **samt Vergleichsoperator** (`>= 80 / >= 90` — „80" allein sagt
   nicht, welche Seite schlecht ist), der Tooltip nennt die Begründungskette
   („OK because disk_used_pct = 0.15 against warn >= 80, crit >= 90 … edit it in
   OU / Policy"); ohne Regel steht „—" mit der Erklärung, dass der Check seinen
   Zustand selbst meldet. Bei fehlendem Wert wird **kein** Vergleich behauptet
   („no value was reported … so nothing could be graded"). Die Daten lagen auch hier
   schon in der API (`ServiceOut.warn/crit_threshold` + `comparison`) — nur die UI
   zeigte sie nicht: dasselbe Muster wie bei `vanished`.
3. Service-Checks in den Checks-Tab falten (ein Ort pro Aufgabe).
4. Benennung vereinheitlichen (zieht sich durch alle Screens, daher zuletzt und
   in einem Zug).


---

## Befunde: Bereich 7 — Resources (Resource-Protokoll)

Anlass: „Resources machen immer noch keinen Sinn." Das Protokoll ist in
`docs/resource-protocol.md` als **ein** Interface mit vier Verben beschrieben
(„the contract is identical across kinds"). Genau das hält die Umsetzung nicht ein.

```
[Identität] Ein Protokoll, zwei Clients
  Beleg:   bossman-ui/src/app/core/services/resource.service.ts:8-13
             — Docstring: "One client for the WHOLE Resource protocol … generic:
               callers pass a ResourceRef and never a kind-specific URL"
           bossman-ui/src/app/core/services/resources.service.ts:63-90
             — dieselben Endpunkte, dieselben sechs Verben, eigene Typen, plus ein
               Sonderfall `if (kind === 'config')`
           Nutzer: shared/resource-inspector → ResourceService (Singular)
                   shared/resource-node    → ResourcesService (Plural)
  Problem: Dasselbe Ding heißt zweimal unterschiedlich (Singular/Plural), ist zweimal
           implementiert und wird von je einer Komponente benutzt — die Datei, die
           „der eine Client" zu sein behauptet, hat einen Zwilling.
  Fix:     Einen Client behalten (den generischen), `resource-node` darauf umstellen,
           den anderen löschen. Kein Backend betroffen.

[Widerspruchsfreiheit] Zwei Typ-Modelle für dieselbe Serverantwort
  Beleg:   resource.service.ts: ResourceDiff / ResourceResult
           resources.service.ts: ResourcePlan / ApplyResult
  Problem: Zwei Screens können dieselbe Antwort unterschiedlich interpretieren und
           darstellen; der `config`-Sonderfall existiert nur in einem der beiden.
  Fix:     Ein Typsatz, aus dem Backend-Schema abgeleitet.

[Parsimonie] Das „eine Interface" ist im Backend sechsfach ausgeschrieben
  Beleg:   bossman/bossman/api/resources.py — 36 Routen:
           {config, docker, helm, package, role, service} × {schema, observe, plan,
           apply, generations, rollback}
           bossman/bossman/services/resources/__init__.py — 0 Bytes, keine
           kind→Klasse-Registry; kein Dispatch, nur handgeschriebene Wiederholung
  Problem: Wenn der Vertrag identisch ist, widersprechen sechs Kopien der eigenen
           Prämisse. Jede neue Art kostet sechs Routen, und die echten Unterschiede
           (config wird per Pfad identifiziert, nicht per {name}) verstecken sich in
           Duplikaten statt sichtbar zu sein.
  Fix:     EINE Routenfamilie /agents/{id}/resources/{kind}/{name}/{verb} plus eine
           Registry kind→Resource-Klasse in services/resources/__init__.py; die
           kind-spezifischen Eigenheiten (Identität per Pfad bei config) als Attribut
           der Klasse, nicht als Routen-Duplikat.

[Falsifizierbarkeit] Nichts erzwingt die Gleichheit des Vertrags
  Problem: Weil es keine Registry und keinen gemeinsamen Router gibt, würde niemand
           merken, wenn eine Art ein Verb anders benennt oder eines vergisst.
  Fix:     Ein Test, der über die Registry iteriert und für JEDE Art alle Verben
           samt Antwortform prüft — der Beobachtungspunkt, der heute fehlt.
```

### Vorschlag (gestaffelt, zur Entscheidung)

1. ~~**UI-Client vereinheitlichen**~~ — **ERLEDIGT**: `resource-node` nutzt jetzt den
   generischen `ResourceService` (Identität per `ResourceRef` statt vier
   Positionsargumenten), `resources.service.ts` ist gelöscht. Dabei zeigte sich der
   dokumentierte Widerspruch praktisch: die beiden Clients modellierten dieselbe
   Antwort unterschiedlich (`applied_at` vs `created_at`, Hülle vs. entpackt) — der
   Compiler hat jeden dieser Fälle gemeldet. Die Hülle (`{resource_key, observed}`)
   bleibt jetzt an **einer** Stelle, art-spezifische Extras (`role`: `status`,
   `unbound`) sind im gemeinsamen Typ **deklariert** statt in einem zweiten Client
   entdeckt zu werden. Live geprüft: Resources-Tab + Inspector funktionieren.
2. **Registry einführen** (`services/resources/__init__.py`) mit kind→Klasse und
   deren Eigenheiten als Attribute.
3. **36 → 6 Routen** zusammenlegen; die alten Pfade bleiben identisch, also kein
   Bruch für Aufrufer.
4. **Vertragstest** über die Registry (Punkt 4 oben).


---

## Befunde: Bereich 8 — Die gesamte Endpunkt-Oberfläche

Vollständige Inventur: **~370 Endpunkte** (481 `@router`-Dekoratoren) gegen alle
UI-Aufrufe. Auftrag war „jeden einzelnen Frontend- und Backend-Endpunkt".

### 8.1 Toter Code — ganze Feature-Familien ohne jeden Aufrufer

Weder UI noch MCP noch Agent rufen diese auf:

| Familie | Endpunkte | Beleg |
|---|---|---|
| `/graphs` (+`/{id}/data`) | 6 | graphs.py:112,120,127,147,174,200 |
| `/clusters` | 4 | clusters.py:134,148,178,201 |
| `/value-maps` | 4 | value_maps.py:47,55,79,98 |
| `/severity-labels` | 2 | severity_labels.py:43,51 |
| `/templates` + `/template-groups` | 11 | templates.py:56,64,80,181,189,197,228,270,306,315,339 |
| `/remediation-policies`, `/remediation-runs`, `/agents/{id}/remediate` | 7 | remediation.py:79,85,111,138,154,174,184 |
| `/time-periods` POST/PUT/DELETE/usage | 4 | time_periods.py:144,167,205,225 (UI liest nur die Liste) |

```
[Falsifizierbarkeit + Parsimonie] 38 Endpunkte ohne Aufrufer
  Problem: Nicht erreichbarer Code kann nicht falsch werden — und nicht richtig.
           Er wird mitgewartet, mitgetestet, mitdokumentiert und suggeriert
           Funktionen, die niemand bedienen kann. Besonders auffällig:
           Remediation (Phase 1+2 gebaut, live keine Oberfläche).
  Fix:     Pro Familie entscheiden: UI nachziehen ODER Endpunkte entfernen.
           Nichts darf „vielleicht später" bleiben — das ist der Limbo-Zustand
           auf Architekturebene.

[Widerspruchsfreiheit] Zwei Routen doppelt registriert = unerreichbar
  Beleg:   runbooks.py:473 GET /runbook-runs und :488 GET /runbook-runs/{run_id}
           registrieren Pfade, die bereits bei :71 und :116 registriert sind.
  Problem: FastAPI behält die erste — die Zeilen 473-497 sind toter Code, der
           aussieht als würde er etwas anderes tun.
  Fix:     Löschen.
```

### 8.2 Drei parallele Wege zu „Soll-Zustand herstellen" — die Wurzel von „Resources machen keinen Sinn"

```
[Parsimonie + Identität] Dieselbe Aufgabe, drei Endpunkt-Familien
  Beleg:   /agents/{id}/state/{observed,plan,apply,generations,rollback}
             — management.py:108,240,261,155,514
           /agents/{id}/resources/{kind}/{name}/{verb}
             — resources.py (48 Endpunkte)
           /agents/{id}/docker-state/{discover,diff,rollback,generations,converge-plan}
             — docker_apps.py:183-250
           dazu Docker doppelt: /agents/{id}/docker/{deploy,remove,containers}
             (docker_apps.py:36,82,55) vs /resources/docker/{name}/{plan,apply,observe}
           und Helm doppelt: helm_apps.py vs /resources/helm/...
           Die UI nutzt BEIDE Wege (agent.service.ts:328-334 und resources.service.ts).
  Problem: Das Resource-Protokoll sollte laut docs/resource-protocol.md „das
           Rückgrat" sein, das genau diese Zersplitterung beseitigt — es ist
           stattdessen als DRITTER Weg daneben getreten. Deshalb „macht Resources
           keinen Sinn": es ist nicht die eine Abstraktion, sondern eine weitere.
  Fix:     Eine Familie ist die Wahrheit. Vorschlag: /resources/{kind}/... wird der
           einzige Weg (es ist der einzige mit Generationen+Rollback für ALLE Arten);
           /state/* und /docker-state/* werden darauf abgebildet oder entfernt.
           Das ist das Refactoring vor dem Release.

[Ausgeschlossenes Drittes] Ein Aufruf, der nur scheitern kann
  Beleg:   resources.service.ts:75 baut /resources/{kind}/.../schema für JEDE Art,
           aber resources.py hat für `config` KEIN /schema (207-250) — config ist
           auch die einzige Art ohne {name}.
  Problem: Die UI kann einen Endpunkt konstruieren, den es nicht gibt; die
           Ausnahme ist nirgends deklariert, sondern in zwei Clients nachgebaut.
  Fix:     Fähigkeiten pro Art in der Registry deklarieren (hat `schema`? braucht
           `{name}`?) und im Client daraus ableiten statt zu raten.

[Parsimonie] Arten ohne jeden Aufrufer
  Beleg:   /resources/package/* und /resources/service/* (12 Endpunkte) werden von
           keiner UI-Datei aufgerufen.
```

### 8.3 Identität — ein Ding, zwei Namen (quer durch die API)

```
[Identität] `agents` und `hosts` bezeichnen dasselbe
  Beleg:   /agents/{agent_id} (agents.py:149) vs /fleet/hosts (monitoring.py:1041),
           /search/hosts (search.py:137), /host-groups (host_groups.py:63),
           /agents/{id}/host-labels (checks.py:679), /provisioning/hosts
           (images.py:212); /agents/{id}/parents liefert HostParentsOut (agents.py:836)
  Fix:     Einen Begriff wählen (im UI heißt es überall „Host"), den anderen als
           Alias-Route behalten, damit nichts bricht — aber nur EINEN dokumentieren.

[Identität] „template" bezeichnet fünf verschiedene Dinge
  Beleg:   /config-templates (config_templates.py:53), /templates (templates.py:181),
           /template-groups (:56), /provisioning/templates (images.py:294),
           /docker/app-templates (docker_apps.py:114)

[Identität] Gleiche Funktionsnamen für verschiedene Dinge
  Beleg:   /sites (search.py:209, `list_sites`) vs /policy-sites (sites.py:76,
           ebenfalls `list_sites`) — einmal Facette, einmal Entität; UI ruft beide.
           /plans (plans.py:111, `list_plans`) vs /orchestration/plans
           (orchestration.py:103, ebenfalls `list_plans`).
```

### 8.4 Widerspruchsfreiheit — schreiben hier, lesen dort

```
[Widerspruchsfreiheit] Retention wird anders geschrieben als gelesen
  Beleg:   PUT /system/retention (system_settings.py:123) schreibt sie;
           es gibt KEIN GET /system/retention — die UI liest
           `run_retention_days` aus GET /system/yolo-mode
           (features/events/event-browser.component.ts:228)
  Problem: Zwei Namen für eine Tatsache; wer die Einstellung sucht, findet sie
           unter einem fremden Begriff.
  Fix:     GET /system/retention ergänzen (oder beides unter /system/settings
           zusammenfassen) und das UI darauf umstellen.
```

### 8.5 Weitere Doppelwege (belegt, geringere Priorität)

`/config-desired` (management.py:413) vs `/desired-state` (orchestration.py:412) ·
`/policy-report?scope_type=` (ou.py:407) vs `/host-groups/{id}/policy-report`
(host_groups.py:151) · Gruppenmitgliedschaft dreifach (PATCH `/agents/{id}/groups`,
PUT `/host-groups/{id}/members`, POST `/agents/mass-update/groups`) · PUT **und**
PATCH mit überlappender Aufgabe (`/host-groups/{id}`, `/policy-sites/{id}`,
`/check-rules/{id}`) · fünf parallele Lauf-Historien (`/runs`, `/runbook-runs`,
`/remediation-runs`, `/restore-jobs`, `/deployments`) · zwei CVE-Leser
(`/agents/{id}/cves` vs `/security/cves?agent_id=`) · Blueprint-GET/POST-Zwillinge
(blueprints.py:148/191 und :162/200) · Widget-Liste zweifach (dashboard.py:168/179) ·
Bulk-Verben in vier Schreibweisen (`acknowledge-bulk`, `mass-update`, `bulk-update`,
`import-bulk`) · `/whatif/scope` bricht kebab-case (ou.py:816).

### Vorschlag: drei Spuren, getrennt entscheidbar

| Spur | Inhalt | Risiko |
|---|---|---|
| **A — Toten Code klären** | 38 Endpunkte: je Familie „UI nachziehen" oder „entfernen"; die zwei doppelt registrierten Routen löschen | gering, rein subtraktiv |
| **B — Zustands-Rückgrat vereinheitlichen** | Resources als **einziger** Weg für observe/plan/apply/generations/rollback; `/state/*` und `/docker-state/*` darauf abbilden; Registry + Fähigkeiten pro Art; Vertragstest | hoch, aber genau das Refactoring vor dem Release |
| **C — Benennung** | `agents`/`hosts` auf einen Begriff, „template" entzerren, `/sites` vs `/policy-sites`, kebab-case, Bulk-Verben | mittel, viele Dateien, mechanisch |
