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
2. ~~**Registry einführen**~~ — **ERLEDIGT**: `services/resources/__init__.py` (vorher
   0 Bytes) enthält jetzt `REGISTRY: kind → ResourceSpec` mit den Eigenheiten
   **deklariert** statt in Route-Duplikaten versteckt: `addressed_by` ('name' bzw.
   'path' für config), `has_schema` (config: False — sein Schema hängt am Codec und
   kommt mit `observe()`), `query_params` (helm: namespace), `extra_verbs`
   (role: binding), `needs_identity` (role: auditiert), plus `label` und `notes`.
   `spec_for()` nennt bei unbekannter Art **die erlaubten Werte** (eine Verweigerung
   ohne Grund ist keine). `as_dict()` gibt die Tabelle als reine Daten heraus, damit
   die UI ihre Fähigkeiten **ableitet** statt zu raten — genau der Fehler, der zum
   nicht existierenden `/resources/config/.../schema` führte.
   **Vertragstest** `tests/test_resource_registry.py` (24 Tests): jede Art
   implementiert die Verben, die sie deklariert; zustandsändernde Verben sind async,
   `schema` bleibt synchron; jede Art nennt sich selbst (`resource_type` + Label);
   `config` bricht die Form **genau** wie deklariert und keine andere Art bricht sie;
   die Historien-Verben gelten für **alle** Arten (eine Resource ohne Generationen
   wäre nicht rollback-fähig — die Lücke, die das Protokoll schließen sollte);
   Eigenheiten stehen nur dort, wo sie hingehören.
3. **36 → 6 Routen** zusammenlegen; die alten Pfade bleiben identisch, also kein
   Bruch für Aufrufer. **Zwischenstand:** beim Ansetzen kam heraus, dass die Arten
   sich in **mehr** Eigenschaften unterscheiden als zunächst deklariert — die
   Registry ist entsprechend vollständig gemacht (`needs_address`,
   `schema_is_async`, `observe_includes_schema`, `generations_scope`), und die Tests
   prüfen jede Behauptung **gegen die Klasse** (sie haben dabei sofort zwei falsche
   Angaben von mir gefangen: package und service haben ein statisches `schema()`,
   nicht `schema_async()`). Wichtigster inhaltlicher Fund: **`role` verlangt bewusst
   keine Host-Adresse** — eine Rollenbindung ist DB-Soll-Zustand, damit ein
   geplanter, noch nicht gebooteter Host Rollen erhalten kann. Diese Eigenschaft war
   nur als Kommentar in einer Route begraben.
   **Stand:** die 17 GET-Routen sind **ERLEDIGT** → zwei generische
   (`/resources/{kind}/{name}/{verb}` und `/resources/config/{verb}`), Pfade
   zeichengleich, `api/resources.py` von 36 auf 21 Routen. Antwortformen live
   nachgewiesen (config trägt weiter sein `schema` in `observe` und `scope: host` an
   `generations`), und die Fehler sind **besser** als vorher: `config/schema` → 404
   „its schema arrives with observe()", unbekannte Art → 400 mit der Liste der
   erlaubten Werte, falsches Verb → 400 mit den Lese-Verben, `role` ohne Plan → 404
   mit der Erklärung, was eine Rolle ist. 92 resource-Tests grün, UI-Inspector live
   geprüft.
   **Offene Entscheidung für den Umbau selbst:** die 18 POST-Routen tragen je Art ein
   **typisiertes Pydantic-Body-Modell** (DockerSpec/HelmSpec/ConfigSpec/RoleSpec …).
   Eine einzige generische Route müsste `dict` annehmen und statt dessen gegen
   `schema()` validieren — das ist die parsimonische Lösung (ein
   Validierungsmechanismus statt sechs), ändert aber die Fehlerform. Die 18
   **GET**-Routen sind dagegen verlustfrei zusammenlegbar (kein Body). Vorschlag:
   GETs jetzt zusammenlegen, POSTs erst nach dieser Entscheidung.
4. **Vertragstest** über die Registry (Punkt 4 oben).


---

## Befunde: Bereich 8 — Die gesamte Endpunkt-Oberfläche

Vollständige Inventur: **~370 Endpunkte** (481 `@router`-Dekoratoren) gegen alle
UI-Aufrufe. Auftrag war „jeden einzelnen Frontend- und Backend-Endpunkt".

### 8.1 Familien ohne Oberfläche — *nicht* automatisch toter Code

> **Korrektur (wichtig).** Diese Tabelle hieß zuerst „Toter Code — ohne jeden Aufrufer".
> Das war falsch etikettiert und hat eine Löschentscheidung auf eine schiefe Grundlage
> gestellt: „ohne Aufrufer" galt nur für **UI, MCP und Agent**. Tatsächlich hat **jede**
> Familie außer Remediation eine **Testdatei**, und drei haben eine eigene Service-Schicht
> (`templates.py`, `time_periods.py`, `remediation.py`). Ein Test *ist* ein Aufrufer.
> Richtig heißt der Befund: **gebaut, getestet, aber nicht bedienbar** — und die Frage ist
> je Familie „Oberfläche nachziehen oder entfernen", nicht „löschen, ist eh tot".
>
> Regelverstoß, den ich selbst begangen habe: Äquivokation über „Aufrufer" (§1) — derselbe
> Begriff meinte in der Inventur etwas anderes als in der Vorlage an den Nutzer.

Weder UI noch MCP noch Agent rufen diese auf (Tests und Service-Schicht siehe Spalten):

| Familie | Endpunkte | Tests | Service | Beleg | Stand |
|---|---|---|---|---|---|
| `/graphs` (+`/{id}/data`) | 6 | ja | ja (graph_data.py) | graphs.py:112,120,127,147,174,200 | **in Dashboards gefaltet, Editor im Add-Widget-Dialog** |
| `/clusters` | 4 | ja | ja (clustering.py) | clusters.py:134,148,178,201 | **Oberfläche gebaut** |
| `/value-maps` | 4 | ja | — | value_maps.py:47,55,79,98 | **Oberfläche gebaut** |
| `/severity-labels` | 2 | ja | — | severity_labels.py:43,51 | **Oberfläche gebaut** |
| `/templates` + `/template-groups` | 11 | **10 E2E** | ja | templates.py:56,64,80,181,189,197,228,270,306,315,339 | **Oberfläche gebaut** |
| `/remediation-policies`, `/remediation-runs`, `/agents/{id}/remediate` | 7 | — | ja | remediation.py:79,85,111,138,154,174,184 | geht in Event-Handling auf |
| `/time-periods` POST/PUT/DELETE/usage | 4 | ja | ja | time_periods.py:144,167,205,225 | **Oberfläche gebaut** |

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

[Ausgeschlossenes Drittes] Ein Aufruf, der nur scheitern kann  — ERLEDIGT
  Beleg:   resources.service.ts:75 baut /resources/{kind}/.../schema für JEDE Art,
           aber resources.py hat für `config` KEIN /schema (207-250) — config ist
           auch die einzige Art ohne {name}.
  Problem: Die UI kann einen Endpunkt konstruieren, den es nicht gibt; die
           Ausnahme ist nirgends deklariert, sondern in zwei Clients nachgebaut.
  Fix:     Fähigkeiten pro Art in der Registry deklarieren (hat `schema`? braucht
           `{name}`?) und im Client daraus ableiten statt zu raten.
  Status:  ERLEDIGT. `GET /api/v1/resource-kinds` liefert die Registry als reine Daten;
           `resource.service.ts` lädt sie einmal und leitet URL-Form, Identitäts-Felder
           und „hat diese Art ein Schema?" daraus ab. Der hartcodierte
           `kind === 'config'`-Sonderfall ist weg. Ein Fallback spiegelt die
           Server-Tabelle, solange der Endpoint noch nicht geantwortet hat — er
           **erfindet** keine Regel, denn genau das Erfinden hat die nicht existierende
           URL erzeugt. Live belegt: die UI ruft /resource-kinds (200) und danach
           schema/observe/generations über die zusammengelegten Routen; eine Anfrage
           an /resources/config/schema kommt nicht mehr vor.

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


---

## Befunde: Bereich 9 — Tests als Beobachtungspunkte (beim Suite-Lauf gefunden)

```
[Falsifizierbarkeit] 16 Tests laufen lokal nie — also prüfen sie nichts
  Beleg:   Voller Lauf: 883 grün, 488 übersprungen, 17 rot. 16 der 17 sind
           DB-gestützte End-to-End-Tests („real HTTP, real Postgres", z.B.
           tests/test_runs_api.py:1-3) mit ConnectionRefusedError, weil der Host die
           Compose-Datenbank nicht erreicht.
  Problem: Ein Test, der nie läuft, ist kein Beobachtungspunkt — er sieht nur so aus.
           Schlimmer: er verdeckt echte Fehlschläge (siehe nächster Befund).
  Fix:     Suite im Container laufen lassen (dort ist die DB erreichbar) oder diese
           Tests als solche markieren, damit „17 rot" nicht zur Normalität wird.
  Status:  ERLEDIGT — `scripts/test-in-container.sh` (mit Begründung im Kopf des Skripts).
           Belegt: dieselben 10 Dateien im Container 60 passed / 0 failed.

  ZWISCHENIRRTUM, ausdrücklich festgehalten (er zeigt, wie der Fehler entsteht):
           Ich hatte behauptet, die 16 könnten „in KEINER Umgebung grün werden", weil
           `db_session` (conftest.py:52-69) nie committet und die Tests deshalb über eine
           fremde Verbindung Unsichtbares lesen. Das ist FALSCH: die Helfer committen
           (tests/test_relationships_api.py:19,37,45). Ich hatte die Fixture gelesen und
           den Testkörper nicht — ein Schluss aus einer unvollständigen Disjunktion (§5),
           gestützt auf die Zahl 16, die in beiden Umgebungen gleich war.
           Widerlegt durch Messung: das Szenario per Hand im Container nachgebaut →
           funktioniert; der Test isoliert → grün; die ganze Datei → grün.

[Widerspruchsfreiheit + Identität] Die Aufräum-Fixture löscht fremde Zeilen — BEWIESEN
  Beleg:   tests/conftest.py:146-149 + `_drop_leaked_agents`: Kriterium ist
           „Name passt auf ^[a-z-]+-[0-9a-f]{8}$ UND created_at >= started".
           Experiment: dieselben drei Testdateien einzeln = grün; ZWEI Läufe gleichzeitig
           gestartet = 10 bzw. 12 Fehler (jeweils in Tests, die allein bestehen).
  Problem: Das Kriterium hat kein Eigentümer-Merkmal. „Nach MEINEM Start angelegt und
           sieht wie ein Testhost aus" trifft auch auf die Zeilen des anderen Prozesses
           zu — jeder Lauf sabotiert jeden parallelen Lauf, und der Fehler erscheint
           irgendwo anders als er entsteht. Genau daraus wurde „16 sind halt rot".
  Fix (jetzt): Serialisierung per `flock` in scripts/test-in-container.sh — zwei Läufe
           können sich nicht mehr überlappen.
  Fix (richtig, offen): Die Fixture darf nur löschen, was ihr EIGENER Prozess erzeugt hat
           (Lauf-Kennung im Testhost-Namen oder mitgeführte id-Liste). Solange die
           Bedingung „fremd" nicht von „eigen" unterscheiden kann, ist sie ein
           Widerspruch zum Zweck der Fixture: sie soll aufräumen, nicht eingreifen.
  Nebenbefund: `uv run` ist im Container Pflicht — PID 1 des Dienstes ist
           `uv run uvicorn …`, das venv wird erst dort synchronisiert. Direkte Aufrufe von
           /app/.venv/bin/python scheiterten an „No module named pytest" bzw.
           „No module named jinja2" und sehen wie Codefehler aus, sind aber keine.

[Widerspruchsfreiheit] Testrückstand in der gemeinsamen Datenbank
  Beleg:   GET /api/v1/host-groups liefert live 36 Gruppen `grp-XXXXXX` mit 0 Mitgliedern.
  Problem: Die Aufräum-Fixture `_drop_test_residue` erfasst Host-Gruppen nicht; die
           Testläufe hinterlassen sie in der EINEN Datenbank (es gibt keine Dev-DB,
           siehe reference-single-database). Jede Gruppenauswahl im UI — auch die neue
           Template-Verknüpfung — zeigt damit Objekte, die es fachlich nicht gibt.
  Fix:     Host-Gruppen in die Rückstandsabsicherung aufnehmen und die 36 Altlasten
           löschen (getrennt entscheiden, weil es Fremddaten sein KÖNNTEN — Namensmuster
           `grp-` + 0 Mitglieder + kein OU ist aber eindeutig).

[Widerspruchsfreiheit] Wer OpenRouter anfordert, bekommt hermes_web
  Beleg:   tests/test_chat_backend.py:128 behauptete BACKENDS == {claude_cli, codex,
           hermes_web} — der Code hat seit dem OpenRouter-Umbau vier
           (services/chat_backend.py:42). Der Test SCHLUG an, ging aber zwischen den
           16 umgebungsbedingten Fehlern unter.
           Beim Nachziehen des Tests fiel der eigentliche Fehler auf:
           chat_backend_for(s, "openrouter").name == "hermes_web"
           — services/chat_backend.py:62 setzte `name` als KLASSEN-Attribut, während
           OpenRouter (OpenAI-kompatibel) dieselbe Klasse benutzt.
  Problem: Das System antwortet auf die Anforderung „A" mit einem Objekt, das „B"
           von sich behauptet. Jede Logzeile, jeder Nutzungsdatensatz und jede
           Fehlermeldung schreibt OpenRouter-Verkehr auf hermes_web.
  Fix:     `name` ist jetzt ein Instanz-Attribut; beide Konstruktionsstellen
           (services/chat_backend.py:323, api/chat.py:81) übergeben `name=OPENROUTER`.
  Status:  ERLEDIGT, Test grün (8/8) und um die vierte Art erweitert.
```

---

## Umsetzung: Check templates — Oberfläche nachgezogen (Spur A, Familie 5)

Nutzerentscheidung: **Oberfläche nachziehen** statt entfernen. Grundlage war die Korrektur
in §8.1 — die Familie war nicht tot, sondern *fertig gebaut und ungenutzt*: `Template`
bündelt `CheckRule`-Zeilen, kann andere Templates **verschachteln** und wird an Host-Gruppen
**verlinkt**; beim Verlinken werden echte `CheckRule`-Zeilen **materialisiert**
(`services/templates.py`, zyklensicher, transitiv).

### Was gebaut wurde

| Ort | Änderung |
|---|---|
| `bossman-ui/.../features/check-templates/check-templates.component.ts` | neu — der Screen (Liste ↔ Detail, Regeln, Verschachtelung, Verknüpfungen) |
| `bossman-ui/.../core/services/monitoring.service.ts` | 9 Methoden für `/templates`, `/templates/{id}/links`, `/template-groups` |
| `bossman-ui/.../core/models/monitoring.model.ts` | `CheckTemplate*`-Typen; `CheckRule` um die Herkunft erweitert |
| `bossman-ui/src/app/app.routes.ts`, `app.ts` | Route `/check-templates` + Navigationseintrag in *Library* |
| `bossman/bossman/api/monitoring.py` | `CheckRuleOut.template_id` / `.source_template_rule_id` |
| `bossman/bossman/api/etag.py` | beide Felder aus dem Versions-Hash ausgenommen |

### Logische Entscheidungen (jede mit ihrer Regel)

```
[Identität] Der Screen heißt "Check templates", nie bloß "Templates"
  Problem: Die UI hat schon "Config templates" und "Disk images", die API zusätzlich
           /provisioning/templates und /docker/app-templates (§8.3). Ein nackter
           Begriff "Template" benennt fünf verschiedene Dinge.
  Fix:     Label, Route (/check-templates) und Typnamen (CheckTemplate*) tragen das
           Qualifikator-Wort. Der API-Name `Template` bleibt; die Übersetzung liegt an
           EINER Stelle (dem Modell-Kommentar in monitoring.model.ts).

[Zureichender Grund] Materialisierte Regeln waren herkunftslos
  Beleg:   CheckRuleOut gab template_id nicht heraus, obwohl PUT/PATCH/DELETE
           template-erzeugte Regeln bereits mit 409 "edit the template instead"
           verweigern (monitoring.py:810,874,994).
  Problem: Das UI konnte die Herkunft nicht nennen und die Bedienelemente nicht
           ausgrauen — die Verweigerung erschien grundlos, erst nach dem Klick.
  Fix:     Beide Herkunftsfelder in der Antwort; im Client als schreibgeschützt
           typisiert (aus CheckRuleInput ausgenommen, der Compiler erzwingt es).

[Falsifizierbarkeit] "Verknüpft" ist jetzt nachprüfbar, nicht nur behauptet
  Problem: Ein Screen, der nur sagt "verlinkt", liefert keinen Beobachtungspunkt für
           "hat es gewirkt?".
  Fix:     Je Verknüpfung wird die ZURÜCKGELESENE Zahl materialisierter CheckRule-Zeilen
           angezeigt (aus /check-rules gefiltert nach template_id + scope_value), und
           bei Abweichung "N von M erwartet".

[Ausgeschlossenes Drittes] Verwaiste Verknüpfung ist ein benannter Zustand
  Problem: TemplateLink speichert den Gruppen-NAMEN als Text (models.py:764, kein FK).
           Eine umbenannte oder gelöschte Gruppe hinterlässt eine Verknüpfung, die auf
           nichts zeigt — vorher unsichtbar.
  Fix:     Gruppenauswahl nur per Dropdown aus /host-groups (kein Freitext); eine
           Verknüpfung ohne passende Gruppe wird rot als "unknown group" markiert.
  Offen:   Der eigentliche Fix ist ein FK auf host_groups.id statt eines Namens-Strings —
           Migration, daher eigene Entscheidung.

[Widerspruchsfreiheit] Keine Aktion, die das Backend verweigern würde
  Fix:     Selbstverschachtelung wird nicht angeboten (API: 422), schon verlinkte
           Gruppen erscheinen nicht in der Auswahl (API: 409), "Add rule" bleibt
           gesperrt ohne Service+Metrik+Schwellwert — mit Begründung im Formular.
           Vor dem Speichern steht, dass die Regeln in N Gruppen neu erzeugt werden;
           Löschen/Trennen nennt die Folge samt Anzahl.

[Intension vs. Extension] Regel und Instanz getrennt gezeigt
  Fix:     "Effective: 3 rule(s) — 2 own + 1 from nested templates" ist die REGEL
           (inkl. ungespeicherter Änderung); "Materialized check rules: 3" ist die
           INSTANZ in der Gruppe. Der Vergleichswert ist bewusst der GESPEICHERTE
           Stand, damit eine offene Bearbeitung die Verknüpfung nicht falsch aussehen
           lässt.
```

### Live verifiziert (test-deployment/Compose, nicht nur gebaut)

1. Zwei Templates per API angelegt, `ui-probe-parent` verschachtelt `ui-probe-base`.
2. Verknüpfung auf `grp-0e670c` → **2** CheckRule-Zeilen materialisiert: die eigene
   (`mem_percent`) **und** die des verschachtelten Templates (`cpu_percent`), jeweils mit
   `scope_type=group` und gesetzter `source_template_rule_id` → der transitive Weg wirkt.
3. Direktes `PATCH`/`DELETE` auf eine so erzeugte Regel → **409** mit Begründung.
4. Im Browser (`:4201/check-templates`): Regel über das Inline-Formular hinzugefügt,
   gespeichert → „Effective: 3" **und** „Materialized: 3" in derselben Ansicht.
5. Templates gelöscht → Cascade räumt die materialisierten Regeln mit ab (0 Restzeilen).

Keine `prompt()`-Dialoge: Formulare sind inline, Bestätigungen laufen über eine Snackbar
mit benannter Folge.

---

## Umsetzung: Wertzuordnungen + Zustandsnamen (Spur A, Familien 3 und 4)

Nutzerentscheidung: bei beiden **Oberfläche nachziehen**. Beide beantworten dieselbe Frage —
*wie wird ein gemessener Wert angezeigt?* — und liegen deshalb an **einem** Ort:
`features/settings/measurement-display.component.ts`, eingehängt in Settings.

```
[Zureichender Grund] Ein Rohwert ohne Wortbedeutung
  Beleg:   services/monitoring.py:1352-1353 bildet den Wert auf ein Label ab, WENN die
           gewinnende Regel eine value_map_id trägt. Dieser Verbraucher war immer live —
           aber es gab keine Oberfläche, um eine Zuordnung anzulegen ODER anzuhängen.
  Problem: Ein `0` in einer Service-Zeile ist nicht selbsterklärend; die Erklärung war
           gebaut und unerreichbar. Beide Hälften mussten kommen: anlegen UND anhängen,
           sonst bleibt es unbenutzbar.
  Fix:     Karte „Value maps" in Settings (Name + Wert→Wort-Paare) UND ein Auswahlfeld
           „Shown as (value map)" im Regelformular der Check templates. Belegt: die
           materialisierte CheckRule trägt die value_map_id bis in die Host-Gruppe.

[Widerspruchsfreiheit] Ein Rohwert kann nicht zwei Wörter bedeuten
  Problem: `mappings` ist ein JSON-Objekt; ein zweimal vergebener Schlüssel überlebt nur
           einmal — das Speichern hätte einen Eintrag STILL verworfen.
  Fix:     Die Dublette wird benannt („Der Rohwert „0" ist zweimal zugeordnet") und
           Speichern bleibt gesperrt. Live geprüft: Sperre greift, nach Korrektur frei.

[Ausgeschlossenes Drittes] „keine Zuordnung" ist ein benannter Zustand
  Fix:     Die Spalte zeigt „raw value" statt leer, und eine Zuordnung, deren Objekt fehlt,
           heißt „unknown map" — nicht leer. Leer ließe offen, ob nichts gewählt wurde oder
           etwas fehlt.

[Identität] Zustände umbenennen ≠ Zustände erfinden
  Beleg:   api/severity_labels.py bietet absichtlich nur GET und PUT; die vier Zeilen sind
           von der Migration gesät.
  Fix:     Die Oberfläche hat kein Anlegen/Löschen, die Zustände stehen in der Skalenordnung
           OK→WARN→CRIT→UNKNOWN (nicht alphabetisch, das verbärge die Ordnung), und über der
           Tabelle steht, dass es reine Anzeige ist. „Speichern" ist gesperrt, solange nichts
           abweicht — ein Knopf, der denselben Wert schreiben würde, ist eine Aktion ohne
           Wirkung.

Live verifiziert: Zuordnung „Up / Down" (0→Down, 1→Up) im Browser angelegt → per API sichtbar;
an eine Template-Regel gehängt → die materialisierte CheckRule in `grp-14db80` trägt die
value_map_id; WARN im Browser auf „Degraded" umbenannt → per API bestätigt und zurückgesetzt.

---

## Umsetzung: Host clusters (Spur A, Familie 2)

Nutzerentscheidung: **Oberfläche nachziehen**. Neuer Screen `Fleet ▸ Host clusters`
(`features/clusters/clusters.component.ts`, `/clusters`).

**Was ein Cluster hier ist** — und was nicht. Das Wort ist im System dreifach belegt:
Monitoring-Cluster (dieser), Kubernetes-Cluster (Helm/kubeconfig), Proxmox-Cluster
(Inventar-Import). Der Screen heißt deshalb **„Host clusters"**, das Modell
`cluster.model.ts` sagt es im Kopf. Ein Cluster **ist** ein Host: `agents`-Zeile mit
`mode="cluster"` und ohne Adresse — nichts pollt ihn, seine Services werden einmal pro
Zyklus aus den Knoten berechnet (`poller.py:733` → `aggregate_all_clusters`). Die Aggregation
ist eine Portierung von Checkmks `cluster_mode.py`.

```
[Zureichender Grund] Ein Modusname sagt nicht, was er tut
  Problem: „worst" / „best" / „failover" in einem Dropdown ist eine Einstellung ohne
           erkennbare Folge.
  Fix:     Jede Option trägt ihren Satz („any node's problem is the cluster's problem"),
           und unter der Auswahl steht die Bedeutung des GEWÄHLTEN Modus.

[Identität] „Preferred node" ist NICHT nur für failover relevant
  Beleg:   services/clustering.py: `pivot = primary if primary in selected else selected[0]`
           — bei worst/best ist der Primärknoten der bevorzugte Pivot im gewählten
           Zustands-Bucket, also der deterministische Gleichstands-Entscheid.
  Problem: Ihn als „failover only" zu beschriften wäre schlicht falsch.
  Fix:     Das Feld heißt je Modus anders und erklärt beides: „decides the cluster's state"
           (failover) bzw. „breaks the tie when several nodes share the selected state".
           Bei failover ohne Primärknoten warnt der Screen, dass der Modus dann wie „worst"
           wirkt und die Einstellung nichts tut.

[Falsifizierbarkeit] Ein Muster, dessen Wirkung man erst nach dem Speichern sieht
  Problem: `service_patterns` entscheidet, welche Services dem CLUSTER statt dem Knoten
           gehören. Blind getippt merkt man einen Tippfehler erst, wenn der Cluster
           dauerhaft leer bleibt.
  Fix:     Die Services der GEWÄHLTEN Knoten werden geladen und als Vorschlags-Chips
           angeboten; je Muster steht, welche Services es beansprucht, „(N service(s),
           reported by M of K node(s))", und ein Muster ohne Treffer wird rot als
           „nothing — this pattern claims no service" benannt. Die Zahl zählt SERVICE-NAMEN,
           nicht Knoten — deshalb heißt die Spalte „Claims these services": drei Knoten, die
           alle „Memory" melden, sind ein beanspruchter Service, und „matches" hätte sich
           als Knotenzahl gelesen.

[Widerspruchsfreiheit] Keine Aktion, die das Backend verweigern würde
  Fix:     Der Cluster selbst wird nicht als eigener Knoten angeboten (API: 422); wird ein
           Knoten abgewählt, der Primärknoten war, fällt die Präferenz automatisch weg
           (sonst 422 „primary_node_id must be one of the cluster's nodes"); „Speichern"
           bleibt gesperrt und NENNT den Grund (kein Name / kein Knoten / kein Muster).
           Andere Cluster sind als Knoten nicht wählbar — mit Begründung im Screen: ihr
           eigener Zustand entsteht im selben Zyklus, ein Aggregat aus Aggregaten hinge an
           der Reihenfolge innerhalb dieses Zyklus.

[Widerspruchsfreiheit über Zeit] Erster Screen, der If-Match sendet
  Beleg:   ClusterOut liefert `version`; api/etag.py `check_if_match` lässt einen Aufrufer
           OHNE If-Match still passieren.
  Problem: Bisher hat keine UI-Stelle den Wert zurückgeschickt — zwei parallele Bearbeiter
           hätten sich gegenseitig überschrieben, ohne dass es jemand merkt.
  Fix:     ClusterService.update sendet If-Match; ein 412 wird als Satz erklärt („Someone
           else changed this cluster while you were editing…"). Live geprüft: PUT mit
           veraltetem Wert → 412 mit der neuen Version in der Meldung.
```

### Live verifiziert am echten Cluster

Es existierte schon ein produktiver Cluster: **MUE-C5 Trio Cluster**, `worst`, drei
Proxmox-Knoten (vpp0221/22/23), geclusterte Services `Memory` + `Host alive`, beide OK.

1. Der Screen lädt ihn, hakt genau die drei Knoten an und schließt den Cluster selbst aus.
2. Je Muster erscheint der Treffer gegen die echten Knoten-Services (28/25/29 Services).
3. „What this cluster reports now" zeigt `Host alive OK` / `Memory OK`.
4. Über einen Vorschlags-Chip `CPU load` beansprucht und gespeichert → per API bestätigt;
   danach **wieder auf den Ursprungszustand zurückgesetzt** (ein produktiver Cluster ist
   keine Testumgebung).
5. PUT mit veraltetem If-Match → 412.
6. `scripts/test-in-container.sh tests/test_clusters_api.py tests/test_clustering.py` → 30 grün.

Nebenbei aufgeräumt: zwei `rel-agent-*`-Hosts, die MEINE früheren Testläufe hinterlassen
hatten (dieselbe Rückstands-Lücke wie bei den `grp-*`-Gruppen, siehe Bereich 9).

---

## Umsetzung: /graphs in die Dashboards gefaltet (Spur A, Familie 1)

### Zuerst: meine Vorlage an den Nutzer war ZU GROB

Ich hatte die Entscheidung so begründet: „Die Dashboards können Reihen bereits ad hoc pro
Widget; ein zweiter Weg zum selben Ergebnis ist nach der Parsimonie-Regel ein Logikfehler."
Das stimmt nicht. Beim Lesen beider Seiten:

| | Dashboard-Widget `timeseries` | Graph |
|---|---|---|
| Reihen | genau **eine** (`config.agent_id` + `config.metric`) | **N** Items, über mehrere Hosts |
| Auflösung | **keine** — rohes `select(Metric)` | tier-bewusst via `query_series` (raw/hourly/daily) |
| Pro Reihe | — | label, color, draw_style, **axis_side links/rechts**, function avg/min/max |
| Graph-Ebene | — | y_axis_mode, show_legend, show_working_time |
| Benannt / wiederverwendbar | nein (Konfig steckt im Widget) | ja |

Es waren also **nicht zwei Wege zum selben Ergebnis**, sondern eine echte Teilmenge — mit
einem messbaren Defekt auf der schwächeren Seite. Die Entscheidung „falten" bleibt richtig,
bedeutet aber: **der Graph ist die Maschine, das Dashboard der Ort** — nicht „Graphen weg".

```
[Parsimonie, mit messbarer Folge] Zwei Implementierungen derselben Berechnung
  Beleg:   services/dashboard.py `_metric_series` (eigenes select(Metric), kein Tier)
           vs api/graphs.py `get_graph_data` (query_series, Tier nach Alter von `since`).
  Problem: Dieselbe Aufgabe, zwei Rechenwege, die NICHT übereinstimmten: ein 30-Tage-
           Rückblick im Widget zog jede Rohzeile, derselbe Zeitraum im Graphen kam
           verdichtet zurück. Redundanz ist hier kein Geschmack, sondern ein Fehler mit
           Laufzeitfolge.
  Fix:     services/graph_data.py ist jetzt die EINE Quelle (`series_for_items`,
           `load_graph`). Beide Aufrufer benutzen sie; der inline-Fall läuft als
           implizites Ein-Item-Graph durch denselben Code.
  Belegt:  inline, 30 Tage → tier `hourly`, 2304 Punkte (vorher roh, 140160 Zeilen liegen
           für diese Metrik vor); inline, 1 Stunde → tier `raw`. Vorher immer `raw`.

[Zureichender Grund] Die Auflösung wandert mit den Daten
  Problem: Ein Diagramm, das still von Minuten- auf Tageswerte wechselt, zeigt für dieselbe
           Metrik eine glattere Linie — ohne dass man erkennen könnte, warum.
  Fix:     `resolution` steht in jeder Reihe und im inline-Fall zusätzlich oben; der
           Renderer fasst gemischte Tiers als „raw + hourly" zusammen statt einen davon
           zu unterschlagen.

[Ausgeschlossenes Drittes] Ein Widget, dessen Graph gelöscht wurde
  Fix:     `{"series": [], "error": "the saved graph … no longer exists"}` — benannt, nicht
           als „keine Daten" getarnt. Live geprüft: Graph gelöscht → genau diese Meldung.

[Widerspruchsfreiheit] Der Renderer behauptete „No data", obwohl Reihen da waren
  Beleg:   dashboard-widget.component.ts prüfte nur `points.length`.
  Fix:     `timeseriesHasData()` prüft alle Reihen; ein Builder zeichnet beide Formen und
           honoriert draw_style und axis_side (eine Metrik in Prozent und eine in Bytes
           brauchen getrennte Achsen — das ist der Grund, warum ein Graph mehr ist als
           „ein Widget mit mehr Linien").
```

### Live verifiziert

Graph „probe cpu vs disk" über **zwei** Hosts mit **zwei Achsen** angelegt (vpp0221
`cpu_core_pct` links, vpp0222 `disk_reads_total` rechts, gestrichelt, function=max):
`/graphs/{id}/data` liefert beide Reihen; ein `timeseries`-Widget mit
`config.graph_id` liefert **dieselben** zwei Reihen samt Achse und Tier — also derselbe
Chart an zwei Orten aus einem Rechenweg. Danach alles wieder gelöscht (Graph + drei
Probe-Widgets).

### Nachgezogen: der Chart-Editor liegt im Add-Widget-Dialog

`features/fleet-overview/add-widget-dialog.component.ts`. Der `timeseries`-Zweig baut jetzt
einen **Graphen** und referenziert ihn — es gibt keinen widget-eigenen Reihen-Weg mehr.

```
[Parsimonie] Ein Ein-Item-Graph und ein "Einzelmetrik-Widget" sind dasselbe Ergebnis
  Problem: Beides anzubieten wäre genau die Redundanz, die dieser Umbau beseitigen soll.
  Fix:     Der Dialog kennt für timeseries nur zwei Quellen: „Build a chart" (legt einen
           Graphen an, eine Linie ist der einfache Fall) und „Reuse a saved chart" — und
           Wiederverwendung ist kein zweiter Weg, sondern dasselbe Objekt an einem weiteren
           Ort. Der Graphname ist mit dem Widget-Titel vorbelegt, damit der eine Weg keinen
           Zusatzaufwand kostet. Das Backend akzeptiert `agent_id`+`metric` weiterhin, damit
           BESTEHENDE Widgets unverändert weiterlaufen; neu erzeugt wird es nicht mehr.

[Widerspruchsfreiheit] Der Dialog darf nicht schließen, bevor der Graph existiert
  Fix:     Speichern legt zuerst den Graphen an und schließt erst mit `graph_id`. Ein Fehler
           (z.B. 409, Name vergeben) hält den Dialog OFFEN und nennt den Grund — stilles
           Schließen hätte ausgesehen, als sei das Widget hinzugefügt.

[Falsifizierbarkeit] Metriken pro HOST, nicht fleet-weit
  Problem: Eine fleet-weite Metrikliste erlaubt, für einen Host eine Metrik zu wählen, die
           er nie sendet — der Chart bliebe dauerhaft leer, ohne Hinweis warum.
  Fix:     Die Auswahl kommt aus `GET /agents/{id}/metrics` (nur die Metriken DIESES Hosts);
           das Metrikfeld ist gesperrt, bis ein Host gewählt ist, und ein Host ohne Metriken
           wird benannt („This host has reported no metric yet").

[Zureichender Grund] Warum es eine zweite Achse gibt
  Fix:     Ab zwei Linien erklärt der Dialog die Achsenwahl („put a line on the right axis if
           its unit differs (percent vs bytes)"), und bei gemischten Achsen bestätigt er, dass
           rechts separat skaliert wird. Zwei Einheiten auf einer Achse plätten sich
           gegenseitig — der Chart lügt dann durch Auslassung.
```

### Dabei gefunden: zwei Metrik-Kataloge, zwei Antworten

```
[Identität] "Welche Metriken gibt es?" wird an zwei Stellen verschieden beantwortet
  Beleg:   api/monitoring.py `/metric-catalog` (fleet-weit) überspringt `check_*_state`
           ausdrücklich („a check's own 0/1/2/3 output, not a measurable metric") — filtert
           aber `process_*` NICHT.
           api/agents.py `/agents/{id}/metrics` (pro Host) filtert `process_*` — aber
           `check_*_state` NICHT.
  Problem: Jeder Katalog schließt aus, was der andere einschließt. Im neuen Auswähler waren
           dadurch 8 der ersten Einträge genau das Rauschen, das der andere Endpunkt
           bewusst entfernt (42 statt 50 Einträge nach dem Filter).
  Fix jetzt: Der Dialog filtert `check_*_state` selbst, mit Begründung im Code.
  Fix richtig (OFFEN, eigene Entscheidung): EINE gemeinsame Ausschlussregel serverseitig,
           von beiden Endpunkten benutzt. Nicht im Vorbeigehen geändert, weil
           `/agents/{id}/metrics` auch die Host-Detail-Metriken speist — eine geänderte
           Semantik dort ist eine Entscheidung, kein Nebeneffekt.
```

### Live verifiziert (Browser, nicht nur API)

1. Add-Widget → „Time series": „Reuse a saved chart" ist korrekt **gesperrt**, solange kein
   Graph existiert.
2. Host `vpp0221` gewählt → Metrikfeld entsperrt, `check_*`-Einträge **0 von 42** (vorher 8
   von 50).
3. Zweite Linie: `vpp0222` / `disk_reads_total`, Achse **rechts**, Funktion **max** → der
   Hinweis wechselt auf „Two axes: the right-hand lines are scaled separately."
4. „Add" → per API belegt: Graph „probe cpu vs disk (dialog)" mit zwei Items (links avg /
   rechts max, eigene Farben) UND ein Widget mit `config = {graph_id: …}`.
5. Nach Reload zeichnet das Widget **beide** Linien — am Canvas gemessen: 13233 grüne
   (#1e9600) und 38156 rote (#d0021b) Pixel. Die ECharts-Instanz ist gebündelt und nicht
   global erreichbar, deshalb der Pixel-Beleg statt einer Annahme.
6. Probe-Graph und -Widget wieder gelöscht; `scripts/test-in-container.sh` über
   test_graphs.py + test_dashboard_api.py: 10 grün.

---

## Umsetzung: Notification windows (Spur A, Familie 7 — damit ist Spur A vollständig)

Nutzerentscheidung: **Oberfläche nachziehen**. Karte „Notification windows" in
Admin▸Notifications (`features/notifications/time-periods-card.component.ts`) — bewusst auf
demselben Screen wie die Regeln, weil ein Fenster nur im Zusammenhang mit den Regeln gelesen
wird, die es benutzen.

Ausgangslage: der Verbraucher war **live** (`time_period_blocks` in services/notification.py
entscheidet, ob eine Regel feuert) und der Regel-Dialog bot die Auswahl schon an — aber es
gab nur das eingebaute `24x7`, weil niemand eine Periode anlegen konnte. „Nur zu
Geschäftszeiten benachrichtigen" war damit unerreichbar.

```
[Zureichender Grund] In WELCHER Uhr wird ein Fenster gelesen?
  Problem: Ein Fenster, das in der falschen Zone gelesen wird, ist um den Ortsversatz
           verschoben — und das ist aus der Definition allein unsichtbar.
  Fix:     Die Zone steht über der Tabelle („Windows are read in Europe/Berlin"), und je
           Fenster steht „open"/"closed" für JETZT (serverseitig ausgewertet). Live belegt:
           `business_hours` (Mo–Fr 08–17) stand um 20:08 Ortszeit korrekt auf „closed".

[Widerspruchsfreiheit] Kein Bedienelement für eine Verweigerung
  Fix:     Built-in: Löschen ist gesperrt MIT Begründung im Tooltip; Umbenennen ist gesperrt,
           solange eine andere Periode diese ausschließt (excludes referenzieren per NAME, ein
           Umbenennen würde sie ins Leere zeigen lassen) — beides vorher gesperrt statt
           hinterher als 409. Selbstausschluss wird nicht angeboten. Speichern nennt seinen
           Blocker.

[Ausgeschlossenes Drittes] „geschlossen ganztägig" ist die LEERE Spannenliste
  Problem: Eine Ausnahme mit leerer Liste heißt in der API „ganztägig zu" — als leere Zeile
           gerendert hätte man sie für „noch nicht ausgefüllt" gehalten.
  Fix:     Eigene Checkbox „closed all day"; das Umschalten setzt bzw. leert die Spannen.

[Falsifizierbarkeit] Was ändert sich, WENN ich das ändere?
  Fix:     /usage wird pro Fenster geladen: die Spalte „Used by" zeigt die Zahl der Regeln,
           und im Editor steht namentlich, welche Regeln betroffen sind — vor dem Speichern.
           Beim Löschen wird die Folge genannt: die Regeln verschwinden nicht (FK ON DELETE
           SET NULL), sie feuern danach rund um die Uhr.

[Widerspruchsfreiheit über Zeit] If-Match auch hier
  Fix:     PUT sendet die `version`; ein 412 wird als Satz erklärt statt als Statuscode.

[Widerspruchsfreiheit] MEIN EIGENER Entwurfsfehler, vom Test aufgedeckt
  Beleg:   Der Validator lehnt Nacht-Spannen ab (ein Ende <= Start wäre ein Fenster, das nie
           zutrifft), und die Oberfläche riet korrekt: „teile 22:00–02:00 in 22:00–24:00 und
           00:00–02:00". Nur: `<input type="time">` KANN `24:00` nicht halten — der Browser
           leert das Feld, und das Speichern kam mit „not a HH:MM time: ''" zurück.
           Ich hatte also zu einem Wert geraten, den mein eigenes Bedienelement nicht
           ausdrücken kann.
  Fix:     „to midnight" ist ein eigenes Bedienelement (Checkbox) statt eines Wertes im
           Zeitfeld; abgewählt fällt es auf 23:00 zurück — ein konkreter, editierbarer Wert,
           kein leeres Feld. Live belegt: gespeichert wurde exakt
           {"monday": [["22:00", "24:00"]]}.
```

### Live verifiziert

Fenster `oncall-nights` über die Oberfläche angelegt: die Sperre „Without any hours this
window is never open, and a rule using it would never fire." erschien, die Nacht-Spanne
22:00–02:00 wurde mit Aufteilungs-Hinweis abgelehnt, nach „to midnight" war Speichern frei,
und die API bekam `{"monday": [["22:00","24:00"]]}` mit „closed right now". Danach wieder
gelöscht. `scripts/test-in-container.sh tests/test_time_periods.py`: 21 grün.

**Nebenbefund, NICHT angefasst:** neben `24x7` liegen `business_hours` und
`company_holidays` in der Datenbank, angelegt am 30.07. sechs Minuten nach dem Seed. Kein
Seed-Skript und keine Migration erzeugt sie, die Namen kommen nur als Beispiel in Docstrings
vor — mutmaßlich manuell angelegte Probedaten einer früheren Sitzung. Ich habe sie stehen
gelassen, weil sie Absicht sein könnten; sie sind als Prüfstoff sogar nützlich. (Meine erste
Vermutung „Rückstand aus heutigen Testläufen" war falsch — die Zeitstempel sind 15 Tage alt.)

---

## Umsetzung: Bereich 1 Restbefunde — Service checks gefaltet, Benennung eindeutig

### Der Befund war schärfer als zuerst notiert

Die Inventur nannte „zwei Orte für eine Aufgabe" (Parsimonie). Beim Umsetzen zeigte der Code
etwas Schlimmeres:

```
[Ausgeschlossenes Drittes] Der Tab „Checks" verbarg eine ganze Klasse von Checks
  Beleg:   host-checks.component.ts:424-429 (vorher) filterte die Kategorie
           „Service checks" AUS der Tabelle heraus — mit dem Kommentar, sie würden in
           Management ▸ Service checks verwaltet („single source of truth").
  Problem: Ein Tab mit dem Namen „Checks" zeigte also NICHT alle Checks dieses Hosts, und
           nichts auf dem Tab sagte, dass etwas fehlt. Das ist keine Redundanz, sondern eine
           Lücke im Zustandsraum: Wer dort nachsieht, ob ein Endpunkt überwacht wird,
           bekommt „nein" zu sehen, obwohl die Antwort „ja, nur woanders" wäre.
  Fix:     Die Sektion ist auf denselben Tab gezogen (die Komponente ist unverändert
           wiederverwendet, nur ohne eigene Überschrift), der Management-Snapin
           „Service checks" ist entfernt. Der Filter bleibt — aber jetzt, weil die Zeilen
           in der Sektion DARÜBER stehen (sonst stünde dieselbe Zeile zweimal auf einem
           Screen), nicht weil sie vom Tab verschwinden.

[Identität] Ein Wort, vier Dinge — jetzt sagt jede Sektion, was eine Zeile behauptet
  Fix:     Vier Sektionen in der Reihenfolge Tatsache → Regel → Regel → Messung, jede mit
           einer Zeile:
             Discovered services  „was discovery auf dem Host gefunden hat — eine Tatsache,
                                   keine Regel"
             Service checks       „Assigned check (a rule): ein Endpunkt, den dieser Host
                                   aktiv prüft"
             Effective checks     „Assigned check (a rule): ein Check aus der Bibliothek, der
                                   für diesen Host gilt"
             Service states       „Service state (a measurement): was ein Check zuletzt
                                   gemeldet hat. Eine Regel oben sagt, WAS gemessen wird;
                                   eine Zeile hier sagt, was zurückkam."
           Der Kopfkommentar der Komponente führt die Vierertabelle Definition / Regel /
           Tatsache / Messung, damit die Begriffe nicht wieder auseinanderlaufen.
           „Monitoring services" heißt jetzt „Service states" — es sind Messungen, keine
           systemd-Dienste, und „Services" war im selben Screen schon anders belegt.

[Identität] Derselbe Titel zweimal auf einem Screen
  Beleg:   Beim ersten Einbau trug die eingebettete Komponente ihre eigene <h3>Service
           checks</h3> — im Browser gemessen: die Überschrift erschien zweimal.
  Fix:     Die Sektion bekommt Überschrift und Erklärzeile vom Tab; die Komponente hat keine
           eigene Überschrift mehr.
```

Aufgeräumt: der Standalone-Shell versteckte den Snapin per `hideSnapins=['servicechecks']` —
eine Referenz, die nach dem Entfernen ins Leere zeigte. Die Standalone-Konsole hat gar keinen
Checks-Tab, dort erscheint also nichts.

Live belegt (`/hosts/<id>?tab=checks`): vier Überschriften in der genannten Reihenfolge,
„Service checks" genau EINMAL, der Knopf „Add a service check" auf dem Tab, kein Verweis auf
„Management ▸ Service checks" mehr im DOM — und im Management-Tab ist die Kategorie
„Monitoring" samt Snapin verschwunden.

---

## Befunde: Gruppen-Mitgliedschaft und Gruppen-Umbenennung (beide live bewiesen, behoben)

Diese zwei Befunde kamen nicht aus der Endpunkt-Inventur, sondern beim Umsetzen der
Metrik-Frage: die Spaltensuche nach „was hält einen Gruppennamen?" hat sie freigelegt.

```
[Widerspruchsfreiheit] Mitgliedschaft war ZWEIMAL gespeichert und lief auseinander
  Beleg:   host_group_members (FK) — geschrieben von PUT /host-groups/{id}/members
           agents.groups (Array von NAMEN) — GELESEN vom Regel-Matching
           (services/scope.py:66, services/monitoring.py:848)
           api/host_groups.py:189 schrieb NUR die erste, api/agents.py:232+295 nur die zweite.
  Messung: Gruppe angelegt, Host per /members hinzugefügt → die Gruppe meldet „1 Mitglied",
           agents.groups bleibt [], und eine gruppenweite CheckRule (warn 0.5 auf cpu_load1)
           erschien in /effective-thresholds NICHT. Die Oberfläche behauptet Mitgliedschaft,
           die Überwachungsmaschine widerspricht, nichts meldet es.
  Ursache: Keine Schlamperei, sondern eine UNFERTIGE Migration — HostGroups eigener Docstring
           sagt: „Distinct from the legacy flat agents.groups string list, which stays
           untouched in L1." Die neue Tabelle kam, der Leser wurde nie umgezogen.
  Fix:     services/host_membership.py ist der EINE Schreibweg. host_group_members ist die
           Quelle (eine Relation zwischen zwei Zeilen kann nur mit Fremdschlüsseln nicht
           baumeln), agents.groups ist eine daraus in derselben Transaktion abgeleitete
           Projektion (Namen bleiben nötig, weil der Name ein PFAD ist). Alle drei Endpunkte
           gehen darüber.
  Status:  ERLEDIGT, 7 Tests in tests/test_host_membership.py; live nachgemessen: derselbe
           Ablauf liefert jetzt groups=['audit-sync2'] UND die Regel gewinnt
           („scope_label: Group audit-sync2, is_winner: true").

[Ausgeschlossenes Drittes] Umbenennen brach jede Referenz still
  Beleg:   api/host_groups.py:92 setzte nur host_groups.name.
  Messung: Gruppe + gruppenweite Regel angelegt, umbenannt → die Regel zeigt auf
           'audit-probe', eine Gruppe, die es nicht mehr gibt; sie gilt für keinen Host mehr.
  Namensträger: check_rules.scope_value, notification_rules.scope_value,
           template_links.host_group UND agents.groups. Ein Fremdschlüssel ist NICHT der Fix:
           der Name ist absichtlich ein Pfad („Europe" regiert „Europe/Latvia").
  Fix:     host_membership.rename_group zieht in EINER Transaktion alles mit, inklusive der
           Pfad-Kinder („Europe/Latvia" → „Neu/Latvia"), und verweigert eine Namenskollision
           VOR dem ersten Schreiben (sonst bricht die Unique-Bedingung mitten in der Kaskade
           ab und niemand weiß, welche Hälfte gilt). Live: die Regel folgt auf
           'audit-sync2-renamed', die Projektion ebenso.

[dieselbe Fehlerklasse, beim Messen der NÄCHSTEN Tür gefunden]
  Nach dem Beheben von Hinzufügen und Umbenennen zeigte die Messung, dass LÖSCHEN die
  Projektion nicht anfasst: der frühere Member behielt den Namen der gelöschten Gruppe und
  hätte weiter auf sie gematcht. Behoben und mit einem eigenen Test belegt.

[Mein eigener Entwurfsfehler, von den Tests aufgedeckt — zweimal]
  1. Die Projektion aus der Tabelle LÖSCHT Namen, die nur im Array standen (Altbestand, alte
     Endpunkte, Fixtures, Enrollment). Ein Test fiel darüber: ein Host mit groups=["Europe"]
     verlor „Europe", sobald „prod" hinzukam. Fix: `adopt_projection` übernimmt Array-Namen
     zuerst in echte Mitgliedschaften — das Array WAR die Wahrheit fürs Matching, also ist es
     die Absicht.
  2. Die Adoption stand an der falschen Stelle: für die VERLIERER einer Mitgliedschafts-
     änderung ist das Array per Konstruktion veraltet, also stellte „adoptiere, was das Array
     sagt" die gerade gelöschte Zeile wieder her. Reihenfolge jetzt: adoptieren → ersetzen →
     projizieren (ohne erneute Adoption). Beim Löschen ebenso VOR dem Löschen, sonst würde die
     Adoption die zu löschende Gruppe neu anlegen.

[Falsifizierbarkeit] Mein eigenes Testskript sicherte nur nominell
  Beleg:   Ein per `timeout` abgebrochener Volllauf ließ seinen CONTAINER weiterlaufen (das
           Signal erreicht die compose-CLI, nicht den Container), der flock wurde mit der
           toten CLI freigegeben — 15 Minuten später löschte der Waise noch die Zeilen der
           folgenden Läufe (25 Fehler, die nach dem Abschießen verschwanden).
  Fix:     scripts/test-in-container.sh gibt dem Container einen festen Namen, entfernt einen
           Rest vor dem Start und räumt per `trap … EXIT INT TERM` auf, wie das Skript auch
           endet.
  Lehre:   Ich habe erst auf einer vorgewärmten Datenbank „20 grün" gesehen; die Gruppen, die
           mein Code selbst erzeugt hatte, machten den Erstlauf-Fall unsichtbar. Erst der Lauf
           gegen 0 Gruppen war ein Beweis.
```

### Umgesetzt: EINE Metrik-Ausschlussregel (Nutzerentscheidung)

`services/metrics_query.is_measurable` + `measurable_sql_filter` sind die eine Regel;
`/metric-catalog` (api/monitoring.py:78) und `/agents/{id}/metrics` (api/agents.py:712) nutzen
sie. Vorher filterte der eine nur `check_*_state` (19 Serien) und behielt `process_*`, der
andere umgekehrt. Live: fleet 54 Einträge, per-host 42, in BEIDEN 0 × `check_*_state` und
0 × `process_*`. Der clientseitige Notfilter im Add-Widget-Dialog ist entfallen.

### Aufgeräumt

36 `grp-XXXXXX`-Host-Gruppen (0 Mitglieder, Testnamensmuster) über die API gelöscht; dabei
kaskadierten 9 test-eigene `access_grants` (1037 → 1028). Danach sind **null** Host-Gruppen
übrig — alle waren Rückstand. Ebenfalls entfernt: ein `groups`-Array-Rest an
test-deployment aus meiner eigenen Probe.

**Nebenbefund, nicht angefasst:** `access_grants` hat 1028 Zeilen; das sieht überwiegend nach
Testrückstand aus und gehört in dieselbe Rückstandsabsicherung wie Hosts und Gruppen (die
Fixture erfasst beide bis heute nicht mit einem Eigentümer-Merkmal — siehe Bereich 9).

---

## Umsetzung: Testrückstand — Eigentümer statt Zeitfenster (Bereich 9, Fortsetzung)

```
[Identität] Das Aufräum-Kriterium konnte fremd nicht von eigen unterscheiden
  Beleg:   tests/conftest.py wählte „Name in Testform UND created_at >= mein Start".
  Messung: dieselben drei Testdateien einzeln grün; ZWEI gleichzeitige Läufe → 10 bzw. 12
           Fehler, weil jeder Teardown die frisch gesäten Hosts des anderen löschte.
  Fix:     tests/naming.py trägt eine Lauf-Kennung (`RUN_TAG`) und `owned_name(prefix)`.
           Aufgeräumt wird, was EIGEN ist (Name trägt die Kennung) ODER WAISE (Testform und
           älter als 2 h, kann also keinem laufenden Prozess gehören). Die frischen Zeilen
           eines parallelen Laufs sind keins von beidem.
  Gegenprobe: zwei gleichzeitige Läufe → 28 grün / 28 grün (vorher 10 bzw. 12 Fehler).
  Nebenbei: der Helfer hieß zuerst `test_name` — pytest sammelt jede Funktion mit `test_`-
           Präfix, also wurde der HELFER als fehlschlagender Test eingesammelt. Vom Collector
           gefunden, nicht vom Lesen; der Grund steht jetzt in naming.py.

[Zureichender Grund] Grants referenzieren ihr Subjekt über den NAMEN
  Messung: 1325 `access_grants`, alle `api_token / all / manage`, davon nur DREI in Testform —
           die Suiten benutzen feste Namen (test-caller, mon-caller, mgmt-caller). 339 davon
           hatten KEIN Token mehr, und 147 Test-Tokens lagen ebenfalls herum.
  Problem: Ein Grant nennt sein Subjekt beim Namen. Ein künftiges Token namens `test-caller`
           erbt damit `scope=all, permission=manage` aus einem Lauf von vor Wochen. Für
           Testnamen ist das Rauschen — für einen echten Tokennamen ist es eine stille
           Rechteerteilung. **Das ist dieselbe Fehlerklasse wie die Gruppen-Referenz per Name,
           und sie ist NICHT behoben: sie gehört dir vorgelegt, weil es eine
           Autorisierungs-Semantik ist, keine Aufräumfrage.**
  Aufräumen (getan): Tokens ZUERST, dann Grants — die erste Fassung hatte es umgekehrt, wodurch
           die Grants eines gerade gelöschten Tokens bis zum nächsten Lauf liegen blieben
           (gemessen: 1325 → 971 statt weg). Danach: baumelnde Grants 339 → 0.
  Stand:   Rückstand ist jetzt BEGRENZT und selbstheilend (jeder Lauf fegt Waisen > 2 h) statt
           unbegrenzt zu wachsen — er war seit 02.08. auf 1325 Zeilen angewachsen. Ein Lauf
           hinterlässt weiter seine eigenen Zeilen, solange die Suite `owned_name()` nicht
           benutzt; migriert ist bisher nur tests/test_host_membership.py als Vorlage.
  Offen:   die übrigen ~20 Testdateien auf `owned_name()` umstellen (mechanisch), dann ist der
           Rückstand nach jedem Lauf null statt nach zwei Stunden.
```

### Umgesetzt: Grants referenzieren ihr Subjekt per UID (Nutzerentscheidung + LDAP-Vorbild)

Die Rückfrage des Nutzers — „warum geben wir nicht Objekten eine uid, so wie LDAP das macht?" —
war besser als meine drei Optionen und beschreibt genau LDAPs Entwurf: ein Eintrag hat einen
**DN** (den hierarchischen Namen) *und* eine unveränderliche **entryUUID**, plus ein
**refint-Overlay**, das DN-Verweise beim Umbenennen und Löschen nachführt.

| LDAP | hier | Stand |
|---|---|---|
| entryUUID | `api_tokens.id`, `host_groups.id` | existierte bereits |
| DN (Pfad) | Gruppenname `Europe/Latvia` | trägt die Vererbung |
| refint bei rename | Umbenennungs-Kaskade | gebaut (a6f75d51) |
| refint bei delete | FK `ON DELETE CASCADE` | **jetzt für Grants** |

Migration `c4f9b2e70a18`: `access_grants.subject_token_id` → `api_tokens.id`, CASCADE, plus ein
CHECK „ein api_token-Grant braucht eine uid". `subject_ref` bleibt — für einen **user** ist der
Name die Identität (es gibt keine andere uid), und in einer Audit-Zeile liest man den Namen.

Live belegt, jeweils mit Grund in der Antwort:

| Prüfung | Ergebnis |
|---|---|
| Grant auf einen Namen mit 2 Tokens | **409** „…a grant binds to one token, so the name is ambiguous" |
| Grant auf einen unbekannten Namen | **422** „no API token named …" |
| Token mit Grant darf verwalten | **200** |
| **gleichnamiges** zweites Token | **403** — erbt NICHT (vorher hätte es geerbt) |
| Identität ohne uid | abgelehnt statt Rückfall auf den Namen |

Vorher gemessen: 1325 Grants, **alle** Testrückstand (`*-caller`), null echte; ein Grant auf
`mon-caller` autorisierte **28** Tokens, `test-caller` 18. Der Rückstand wurde vor der Migration
entfernt, damit nichts geraten werden musste.

**Eigene Fehler in diesem Schritt, beide von Tests gefunden:** `ApiToken.id` hatte nur einen
Server-Default und war vor dem Flush `None` (jetzt client-seitig erzeugt, wie in
api/templates.py), und mein pauschales Test-Patch nahm überall die Variable `row` an —
`test_users_acl.py` hatte gar kein Token, weil es die alte Namens-Semantik prüfte. Dieser Test
prüft jetzt das Gegenteil: ein gleichnamiges Zweit-Token erbt nichts.

**Folge-Anpassung:** `test_update_agent_groups` erwartete Einfügereihenfolge; die Projektion
sortiert bewusst, damit das Array eine Funktion der Mitgliedschaft ist und nicht der Tippreihenfolge.

---

## Bereich: Rollen & Features — Universalität über Distributionsfamilien

Anlass ist die Nutzerfrage: *„bei Debian heißt Apache, Apache — aber bei RedHat httpd. Werden
solche Namensunterschiede berücksichtigt?"*

**Erste Antwort war falsch und wird hier korrigiert.** `configs/roles_features_seed.json`
(73 Einträge, vier Felder, alles Debian) hat keine Familien-Achse — aber das ist nur ein **Seed**
für `bossman/scripts/classify_roles_features.py`. Was die UI liest, ist
`configs/package_catalog.json` über `api/package_catalog.py:26`, und **der hat eine Familien-Achse**:
90 Einträge, je ein `debian`- und ein `redhat`-Zweig mit `packages`, `service`, `config_path`;
aufgelöst in `api/package_wizard.py:91`. Die Frage ist also nicht *ob* übersetzt wird, sondern
*ob die Übersetzung stimmt*. Gemessen:

### [Ausgeschlossenes Drittes] 78 von 90 RedHat-Zweigen sind wortgleiche Debian-Kopien

```
Beleg:   configs/package_catalog.json — nur 12 der 90 Einträge haben einen redhat-Zweig,
         der sich vom debian-Zweig unterscheidet (apache2→httpd, bind9→bind, snmpd→net-snmp,
         postgresql, proftpd, redis, libvirtd, pacemaker, iscsi-target, tftpd-hpa,
         docker-daemon, nfs.conf). Die übrigen 78 wiederholen den Debian-Namen.
Problem: Ein falscher Zweig ist schlimmer als ein fehlender. Der Fallback in
         package_wizard.py:91 (`fams.get(family) or fams.get("debian")`) kann nicht greifen,
         weil der Eintrag beantwortet AUSSIEHT. Es gibt keinen Zustand „für diese Familie
         unbekannt" — jeder Eintrag behauptet Wissen, das er nicht hat. Das ist genau der
         fehlende dritte Zustand.
Fix:     Ein Zweig darf FEHLEN (→ Zustand „für diese Familie nicht kuratiert", sichtbar in
         der UI, Install gesperrt mit Grund) statt still den Debian-Namen zu behaupten.
         Dann die belegten Übersetzungen nachtragen.
```

Nachweislich falsche Kopien (RHEL kennt den Namen nicht):

| Katalog (Debian) | RedHat tatsächlich |
|---|---|
| `cron` | `cronie` (Dienst `crond`) |
| `nfs-kernel-server` | `nfs-utils` (Dienst `nfs-server`) |
| `slapd` | `openldap-servers` |
| `krb5-kdc` | `krb5-server` |
| `isc-dhcp-server` | `dhcp-server` |
| `exim4` | `exim` |
| `redis-server` | `redis` |
| `auditd` | `audit` (Dienst `auditd`) |
| `pdns-server` | `pdns` |
| `wireguard` | `wireguard-tools` |
| `prometheus-node-exporter` | `golang-github-prometheus-node-exporter` |
| `docker.io` | `docker-ce` |
| `ufw` | `firewalld` — **anderes Werkzeug** |
| `apparmor` | existiert nicht — RHEL nutzt SELinux |
| `ntp` | `chrony` — **anderes Programm** |

Die letzten drei sind kein Übersetzungs-, sondern ein **Modellproblem**: es gibt für sie kein
Gegenstück, nur einen Ersatz mit anderer Semantik. Dafür braucht der Eintrag ein benanntes
`unavailable` mit Begründung — nicht einen stillen Debian-Namen, der ins Leere installiert.

### [Identität] Die vierte Achse — der Systembenutzer — fehlt vollständig

```
Beleg:   configs/package_catalog.json — je Familie existieren GENAU drei Achsen
         (packages ×180, service ×180, config_path ×180); ein `user` kommt nirgends vor.
Problem: apache läuft als www-data (Debian), apache (RedHat), wwwrun (SUSE). Jede Regel, die
         Dateirechte, Log-Eigentum oder eine Prüfung „läuft als" formuliert, ist damit an eine
         Familie gebunden, ohne es zu sagen.
Fix:     vierte Achse `user` (optional `group`) je Familien-Zweig.
```

### [Gültige Ableitung] SUSE/Arch bekommen still Debian-Namen

```
Beleg:   Familien-Abdeckung gemessen: debian 90, redhat 90, suse 0, arch 0, ubuntu 0.
         api/package_wizard.py:25-33 kennt aber mehr Familien als der Katalog bedient.
Problem: Auf einem SUSE-Host greift der Debian-Fallback und der Wizard schlägt `apache2` vor.
         Das ist hier zufällig richtig (SUSE nutzt apache2), aber aus dem falschen Grund —
         und bei `cron`/`ufw`/`nfs-kernel-server` ist es falsch. Ein Fallback, der nicht sagt,
         DASS er Fallback ist, ist eine unbelegte Verallgemeinerung.
Fix:     Der Wizard markiert einen Fallback als solchen („keine SUSE-Angabe, zeige Debian") —
         zureichender Grund statt stiller Übernahme.
```

### [Falsifizierbarkeit] Die naheliegende Auto-Ableitung wurde geprüft und trägt nicht

`configs/package_universe_real.json` enthält `debian["apache2"].desc == redhat["httpd"].desc ==
"Apache HTTP Server"` — identische Beschreibung bei disjunkten Namen. Klingt nach automatischer
Zuordnung. Gemessen: RedHat hat dort **349** Pakete gegen **8555** bei Debian, nur **13**
Beschreibungen überschneiden sich, davon ergibt **genau eine** eine Übersetzung (eben apache2→httpd).
Der Mechanismus stimmt, die Datenbasis trägt ihn nicht. **Also die 90 Einträge explizit pflegen.**

### [Parsimonie] Der Paketmanager im Management-Tab

Der Einwand des Nutzers gegen den ersten Entwurf war zwingend: ein Snapin, das **entfernen** kann,
was es nicht **installieren** kann, bietet zwei ungleiche Verben für dasselbe Ding. Und „Rollen &
Features massiv erweitern" hieße, ein Repo mit 8555 Paketen von Hand zu kuratieren.

Auflösung: es sind **zwei Objekte**, und die Grenze ist eine **prüfbare Tatsache**:

| | Quelle | Verben | Formular |
|---|---|---|---|
| **Rolle/Feature** | kuratierter Katalog (90) | installieren, entfernen, **konfigurieren** | ja — Template/Codec vorhanden |
| **Paket** | Repo **des Hosts** | suchen, installieren, entfernen, pinnen | nein |

*Ein Paket ist genau dann eine Rolle, wenn wir es auch konfigurieren können.* Kein redaktioneller
Schnitt, sondern prüfbar — und damit falsifizierbar. Beide Snapins haben **symmetrische** Verben;
keine Aufgabe bekommt einen zweiten Ort.

Die Liste kommt **vom Host**, nicht aus `package_universe_real.json` (RedHat-Rumpf, kennt zusätzliche
Repos eines konkreten Hosts ohnehin nicht). `internal/modules/package_facts.go:50` liefert
*installiert* bereits familien-agnostisch (dpkg-query, rpm-Fallback). Es fehlt **genau ein** Verb im
Agenten: **suchen** (`apt-cache search` / `dnf search`).

### Umgesetzt — und wo der Defekt wirklich saß

Die Suche nach der Ursache führte auf **zwei Zeilen**, nicht auf eine Redaktionsentscheidung:

```
bossman/scripts/classify_roles_features.py:222   for fam in ("debian", "redhat")
bossman/scripts/build_package_catalog.py:234     {"debian": _fam(...), "redhat": _fam(...)}
```

Beide schreiben denselben Debian-Namen in **beide** Familien. Keine von beiden hatte je eine
RedHat-Tatsache zur Hand — der Seed ist Debian-abgeleitet, die Codec-Registry ebenso. Die 78
Kopien sind also nirgends beschlossen worden; sie sind das Ergebnis einer Dict-Comprehension.
Beide Generatoren geben jetzt nur noch den Zweig aus, den sie kennen.

Für den **Bestand** kuratiert `bossman/scripts/curate_family_branches.py` (idempotent, `--dry-run`)
die 90 Einträge in vier belegte Ausgänge:

| | Zahl | Grund |
|---|---|---|
| behalten | 46 | echte Übersetzung, CORE-Handentscheidung, oder Name im RedHat-Universum belegt |
| kuratiert | 23 | geprüfte Korrektur aus `CORRECTIONS` (cron→cronie, slapd→openldap-servers, …) |
| unavailable | 3 | apparmor / ufw / ntp — benannte Nicht-Existenz **mit** Ersatzhinweis |
| verworfen | 18 | Kopie ohne Beleg → der Eintrag liest sich jetzt „für RedHat nicht kuratiert" |

46+23+3+18 = 90: kein Eintrag im Limbo. Die **vierte Achse** ist in 34 Zweigen gefüllt
(`www-data` / `apache` / `wwwrun`); wo sie fehlt, heißt das *unbekannt* und nicht *irgendwas*.

`api/package_wizard._resolve_family` macht daraus vier erschöpfende, disjunkte Zustände —
`exact` / `fallback` / `unavailable` / `unknown` — jeder außer `exact` mit Begründung. Der
frühere stille Fallback konnte nicht helfen: ein erfundener Zweig erfüllt `fams.get(family)`,
also lief er nie. **Abwesenheit ist der Zustand, über den man reden kann.**

Belegt durch `tests/test_package_wizard_family.py` (9 Tests): die vier Zustände über den echten
Katalog × drei Familien (auch `suse`, das gar keinen Zweig hat und deshalb überall `fallback`
liefern muss), „verweigert nie ohne Grund", und ein Test, der die Kopien nicht zurückkommen lässt.

---

## Bereich: Gruppen — Ort, Eigenschaft, Rang (Punkte 1–4)

Ausgelöst durch die Nutzerfrage nach einer „Duplikats-Anomalie": Host in OU A, seine Gruppe in OU B,
Regeln an beiden — welche sticht? Die Messung drehte die Frage um.

### Der Befund: eine zweite Platzierungsachse, die niemand auswertete

```
[Identität] host_groups.ou_id war ein Ort, den kein Auflöser liest
  Beleg:   resolve_ou_ancestry (agent.ou_id), resolve_host_group_ids (nur Mitgliedschaft),
           affected_agent_ids, scope.py:60, notification.py:218 — alle nehmen die OU
           ausschließlich aus agents.ou_id. Gelesen wurde das Feld nur von
           api/ou.py:309 (Objektliste) und der eigenen CRUD.
  Problem: die Kollision KONNTE nicht auftreten, weil die Gruppen-OU nichts beitrug —
           gleichzeitig versprach das UI eine Wirkung, die es nicht gab. Und hätte man sie
           beigetragen, wäre die Kollision unauflösbar: GPO ordnet nach Tiefe entlang EINER
           Kette, zwei Zweige haben keine relative Tiefe.
  Messung: 0 von 5 Gruppen nutzten das Feld.
  Fix:     Feld gelöscht (d7a3f1c95e24). Windows-Vorbild: eine GPO verknüpft mit
           Site/Domain/OU, NIE mit einer Gruppe; Mitgliedschaft wirkt als Security Filtering.
```

Ein 409-Riegel gegen widersprüchliche Platzierungen (6406eec9) wurde drei Commits später
**wieder entfernt** — dass er überflüssig wurde, war das Zeichen, dass er ein Symptom behandelte.

### Was daraus folgte

| Begriff | Rolle | Träger |
|---|---|---|
| **OU** | der *eine* Ort, Vererbung, Präzedenz nach Tiefe | `agents.ou_id` |
| **Gruppe als Eigenschaft** | querschneidende Menge, ortlos | `host_group_members` |
| **Gruppe als Filter** | Security Filtering auf eine Regel | `conditions.host_groups` |
| **Gruppe als Scope** | Regel *für* diese Menge, eigener Rang | `scope_type='group'` |

### Punkt 4: warum Scope und Filter *keine* Dublette sind

```
[Parsimonie — geprüft und verworfen] scope_type='group' bleibt
  Beleg:   gpo.py:25-27 LEVEL_GLOBAL 0 < LEVEL_GROUP 1 < LEVEL_OU_BASE 2;
           monitoring.py:145 subrank = scope_value.count("/")
  Prüfung: Ein Filter kann zweierlei NICHT: (a) einen Rang zwischen global und OU — als
           „global + Filter" fiele die Regel auf Ebene 0 und würde per link_order entschieden,
           also willkürlich statt spezifisch; (b) Spezifität unter geschachtelten Gruppen —
           „Europe/Latvia" schlägt „Europe" über den subrank, eine flache Liste hat dafür
           keinen Begriff.
  Ergebnis: verschiedene Werkzeuge, keine zwei Wege zum selben Ergebnis. Der Einwand
           „eine Gruppe mit LEVEL verhält sich wie ein Ort" löst sich daran auf, was der
           Level IST: ein Rang in der Mischreihenfolge, keine Position im OU-Baum.
  Festgenagelt: tests/test_group_scope_vs_filter.py — inklusive des Tests, der zeigt, worauf
           „global + Filter" degradieren würde (link_order entscheidet).
```

### Punkt 3: der Filter gilt jetzt überall

Zehn Tabellen tragen `conditions` (`business_services`, `check_assignments`, `check_rules`,
`compliance_rules`, `config_policies`, `config_policy_sets`, `notification_rules`,
`orchestration_plan_links`, `remediation_policies`, `scheduled_jobs`) — ein Matcher, ein
Batch-Helfer (`filter_agent_ids`).

**Eine dokumentierte Ausnahme:** `ScopeVars` bekommt die Spalte *nicht*, weil
`resolve_scope_vars` **von** `build_match_context` aufgerufen wird — eine bedingte
Variablenmenge ruft sich selbst. Ein Test behauptet die Abwesenheit samt Grund, damit die
Ausnahme sichtbar ist und nicht wie ein Versehen aussieht.

## Bereich: Template-Katalog — ein Paket, zwei Namen, zwei Antworten

Aufgetaucht beim Entfernen von `configs/.qualify_pipeline_state.json.bak-llmcrash` (einer
LLM-Crash-Sicherung, die im Repo lag). Der einzige Pfad, den die Sicherung kannte und der
Live-Stand nicht, war `gridengine_exec` — mit **Unterstrich**. Auf der Platte liegen
`gridengine_exec` *und* `gridengine-exec`. Diesem einen Zeichen nachgegangen:

### [Identität] 278 Template-Verzeichnisse tragen den Paketnamen in zwei Schreibweisen

  Beleg:   `configs/config_templates/` — 278 Paare `<name mit _>` / `<name mit ->`
           (`aardvark_dns`/`aardvark-dns`, `avahi_daemon`/`avahi-daemon`, …).
           Herkunft belegt: die Unterstrich-Seite sind Schlüssel aus
           `configs/package_seed.json` (1487 Einträge, alle mit `_`), die Bindestrich-Seite
           sind echte Debian-Paketnamen aus `configs/package_universe_real.json`.
           `qualify_packages.py:1391` startet die Worklist mit *jedem* Verzeichnis auf der
           Platte, also füttert sich jede Schreibweise selbst weiter.
  Problem: Ein Paket, zwei Namen — und beide Schreibweisen wurden **unabhängig durch den
           LLM-Lauf geschickt**: im Pipeline-State stehen 286 Paare, davon 273 beidseitig
           auf `v6-enriched`. Kein einziges Paar ist byte-identisch, es gibt also zu einem
           Paket zwei verschiedene Antworten.
  Fix:     Die Verzeichnisnamen auf **eine** Schreibweise normalisieren (der echte
           Paketname, also Bindestrich — das ist der Name, den Universum, Katalog und
           `apt` benutzen), und `package_seed.json` beim Lesen einmalig normalisieren
           statt seine Schlüssel als zweite Identität weiterzutragen.

### [Ausgeschlossenes Drittes] Der Verzeichnisname sagt nicht, welche Datei er konfiguriert

  Beleg:   `aardvark_dns/template.j2` rendert `/etc/aardvark-dns/aardvark-dns.conf`
           (Seed-`config_path`), `aardvark-dns/template.j2` rendert
           `/etc/aardvark-dns/forward.conf` — eine **andere Datei desselben Pakets**.
           `apt-cacher-ng/template.j2` beginnt mit `#!/bin/sh`: es rendert das
           Expire-Shellskript, nicht die Konfiguration.
  Problem: Die Paare sind damit nicht durchweg Dubletten, sondern teils zwei *verschiedene*
           Dateien unter zwei Namen, die sich nur im Trennzeichen unterscheiden — der
           Zustandsraum „welche Datei gehört zu diesem Verzeichnis" ist nirgends notiert.
  Fix:     `target_path` in die Template-Metadaten schreiben (steht schon als Aufgabe im
           Konsolidierungsplan) und den Verzeichnisnamen aus Paket **und** Zieldatei
           bilden, wenn ein Paket mehrere Dateien hat.

### [Gültige Ableitung] Die Basename-Heuristik greift daneben — belegbar

  Beleg:   `host-detail.component.ts:3144-3147` — `templateFor(path)` nimmt den Basename
           ohne `.conf`/`.cfg` und sucht ein gleichnamiges Template.
  Problem: Für `/etc/aardvark-dns/aardvark-dns.conf` liefert das das Verzeichnis
           `aardvark-dns` — welches `forward.conf` rendert. Der Knopf „Edit via template"
           würde also den Inhalt der einen Datei in die andere schreiben. Ein Schluss von
           Namensähnlichkeit auf Identität.
  Fix:     Auflösung über den `target_path`-Index, nicht über den Basename; ohne Treffer
           **keinen** Knopf anbieten (verweigern mit Grund ist richtig, falsch rendern nicht).

### [Identität] 27 Rollen haben keinen Konfigpfad, obwohl der Seed ihn kennt

  Beleg:   `configs/package_catalog.json` — 30 von 89 Rollen haben
           `families.debian.config_path == ""`; für **27** davon steht der Pfad in
           `package_seed.json` unter dem unterstrichenen Schlüssel: `cron` →
           `/etc/crontab`, `isc-dhcp-server` → `/etc/dhcp/dhcpd.conf`, `clamav` →
           `/etc/clamav/clamd.conf`, `krb5-kdc` → `/etc/krb5kdc/kdc.conf`, …
  Problem: Zwei Quellen der Wahrheit für **eine** Tatsache, und die benutzte ist die
           leere. Genau dieser leere Pfad ließ den Dateipicker bei `libvirt-daemon` die
           flachste Conffile nehmen (`/etc/default/libvirtd`, 6 Variablen) statt
           `/etc/libvirt/libvirtd.conf` (17 kB) — derselbe Defekt, 27 weitere Male.
  Fix:     Beim Katalogbau den Seed-Pfad übernehmen, wenn der Katalog keinen hat
           (Schlüssel per `-`→`_` nachschlagen). Eine Zeile, kein LLM-Aufruf.

**Rangfolge.** Der Konfigpfad-Befund zuerst — er ist eine Zeile Code, betrifft 27 Rollen und
verhindert, dass weitere Templates auf die falsche Datei gebaut werden. Danach die
Auflösung (`target_path`-Index statt Basename), weil sie ein *falsches Schreiben* verhindert.
Die 278 Doppelverzeichnisse zuletzt: sie kosten Platz und haben LLM-Zeit gekostet, aber
welches Verzeichnis das bessere ist, hängt an der Zieldatei — also nach dem `target_path`.
Nichts davon wird gelöscht, bevor die Zieldateien bekannt sind; deprecated wird nach
`config_templates/_deprecated/`, damit nichts still verschwindet.

### Umgesetzt (Befund 4): ein Resolver, zwei belegte Quellen, eine widerlegte Behauptung

`main_config_path(pkg, codecs, seed)` in `build_package_catalog.py` ist jetzt die **einzige**
Antwort auf „was ist die Hauptkonfiguration dieses Pakets"; der Classifier hat seine eigene
Kopie verloren, und `curate_catalog.py` reparieren damit auch die Einträge, die ein früherer
Lauf schon leer geschrieben hat (der Builder *bewahrt* die, also hätte eine reparierte Regel
mit unreparierten Daten niemand beobachten können).

**Die Reihenfolge war der eigentliche Fix.** Zuerst der Seed-Pfad (mit dem Codec-Register als
Zeuge, dass es die Datei wirklich gibt), danach die Stamm-Regel des Registers. Grund: die zwei
Quellen beantworten verschiedene Fragen — der Seed behauptet „das ist die **Haupt**konfiguration",
das Register kann nur sagen „das ist **eine** Konfigurationsdatei dieses Pakets". Registry-zuerst
lieferte `sudo` → `/etc/sudo.conf` (die Plugin-Konfiguration) statt `/etc/sudoers`.

Zwei weitere gemessene Korrekturen: `/etc/restic` ist das Konfig**verzeichnis** — die Stamm-Regel
akzeptierte den Stamm ohne Folgesegment, und `config_path` speist `template_render`, das *eine
ganze Datei* schreibt; ein Verzeichnis ist dort kein Beinahe-Treffer, sondern ein unbeschreibbares
Ziel. Und `/etc/default/etcd` fällt als ancillary heraus.

**Gegen das echte Archiv geprüft, nicht weiter heuristisiert.** Acht Pfade hingen allein an der
Seed-Behauptung. Auf einem Debian-13-Host per `apt-get download` + `dpkg-deb -c` (ohne Installation)
nachgesehen — und der naive Test „ist es ein conffile?" hätte **drei richtige verworfen**:

| Rolle | Pfad | Befund im Archiv | Urteil |
|---|---|---|---|
| `pacemaker` | `/etc/crm/crm.conf` | **crmsh** liefert die Datei | widerlegt |
| `cron` | `/etc/crontab` | `cron-daemon-common` (Abhängigkeit von `cron`) | gültig |
| `openssh-server` | `/etc/ssh/sshd_config` | liefert `/usr/share/openssh/sshd_config`, per ucf installiert | gültig |
| `sssd` | `/etc/sssd/sssd.conf` | `sssd-common` besitzt `/etc/sssd/`, Datei legt der Admin an | gültig |
| `ntpsec`, `rsyslog`, `sudo` | — | echte conffiles des Pakets | gültig |
| `mysql-server` | — | auf dem Testhost nicht ladbar | ungeprüft, unverändert |

„Kein conffile" ist also **kein** Beleg für einen falschen Pfad; „ein anderes Paket liefert sie"
ist einer. Die eine Widerlegung steht mit Begründung in `_SEED_PATH_REFUTED`, damit sie nicht
versehentlich neu verhandelt wird — und sie hat prompt die richtige Antwort freigelegt:
`pacemaker` fällt jetzt auf `/etc/corosync/corosync.conf`, bezeugt über `corosync`, das die Rolle
selbst installiert.

**Ergebnis:** 14 von 30 leeren Pfaden gefüllt, idempotent (zweiter Lauf: 0). Die **16**
verbleibenden werden **namentlich** gemeldet (`paths empty`), weil „wir haben keinen gefunden" und
„niemand hat geschaut" sich sonst gleich lesen. 10 Tests in `bossman/tests/test_main_config_path.py`
nageln jede Regel an dem Fehler fest, aus dem sie entstanden ist.

### Umgesetzt (Befund 3): Pfad→Template-Index statt Basename — und was er unterwegs aufdeckte

`GET /api/v1/config-templates/index` beantwortet „welches Template rendert **diese** Datei" aus zwei
belegten Quellen (Katalog-`config_path`, dann Codec-Register). Die Basename-Heuristik ist weg, und mit
ihr ein **33,7-MB-Download**: die Host-Seite holte alle 5460 Template-*Körper*, um einen Zeichenketten-
vergleich zu machen. Jetzt 223 KB Paare, der Körper wird beim Öffnen einzeln geladen. Ohne Treffer
**kein Knopf**; mit Treffer nennt der Tooltip den Grund („declared as the config file of role nginx"
bzw. „this path is listed in the codec registry").

**Der Index war ein Messinstrument, und die Messung war unangenehm.** Drei Funde, jeder von der Art
„Configure hätte die falsche Datei überschrieben":

| Fund | Beleg | Wirkung ohne Fix |
|---|---|---|
| `openssh-server` zeigte auf ein **ufw-Anwendungsprofil** | `[OpenSSH] title= … ports=22/tcp`, `config_path=/etc/ssh/sshd_config` | fünf Zeilen Firewall-Profil über die SSH-Konfiguration → Aussperrung |
| `chrony` rendert `/etc/default/chrony` | erste Zeile „Chrony daemon options wrapper", Schema = 12 chrony.conf-Direktiven | Wrapper über `/etc/chrony/chrony.conf` |
| **437 von 3488** Codec-Einträgen zeigten auf abgelehnte Templates | `/etc/X11/Xsession` → Shell-Skript, `/etc/bzip2`, … | Shell-Skript als „Konfiguration" geschrieben |

**Der Torwächter war die Ursache, nicht der Zufall.** `_template_configures` fragte „kommt ein
Schemafeld irgendwo im Text vor". Seit die Templates **selbstdokumentierend** erzeugt werden — jede
Direktive mit ihrem Kommentar darüber, wie es die globale Regel verlangt — ist diese Frage **vakuum**:
die Dokumentation des Feldes erfüllt den Test. Die Konvention hat den Test entwaffnet. Jetzt zählt nur
noch, ob das Feld **eingesetzt** wird (`{{ }}`/`{% %}`). Neu gemessen über 76 Katalog-Templates: 54
bleiben True, 19 bleiben None, **genau 3 kippen** auf False — `squid` (rendert die ausgelieferte
Beispieldatei „WELCOME TO SQUID 6.13", 0 Platzhalter), `opendkim` (Datei sagt über sich selbst „not
used by the opendkim systemd service"), `lighttpd` (Platzhalter für Namen, die nicht im Schema stehen).
Alle drei per Augenschein bestätigt.

Zweitens ist das **„ja" jetzt enger als das „nein"**: ein Feldtreffer bei ≤2 Feldern liefert `None`
statt `True` — bei der Größe ist er Zufall (`port` steht in jedem Init-Skript). 19 von 89 Rollen
„bestanden" vorher so.

Drittens lebt die Regel jetzt in `bossman/services/template_gate.py`, **nicht** in `scripts/`. Grund
ist eine Einbahnstraße: der Server kann `scripts/` nicht importieren, `scripts/` aber das Paket. Genau
deshalb war der Index ohne Tor ausgeliefert worden — die Regel war für ihn unerreichbar.

**Und ein Fehler, den nur die Messung zeigte:** der Ergebnis-Cache griff nie, weil die Codec-Schleife
`key` neu band und damit den Cache-Schlüssel überschrieb. Drei Aufrufe à 520 ms statt 548/6/6. Der Test
prüft deshalb die **Objektidentität**, nicht bloß Gleichheit.

**Offen und benannt:** 25 Pfade werden von **zwei** Template-Verzeichnissen beansprucht
(`/etc/haproxy/haproxy.cfg` von `haproxy` und `haproxy.cfg`, beide existieren). Der Index entscheidet
per Vorrang (Katalog vor Codec) und **meldet den Verlierer** — welches inhaltlich richtig ist, gehört
zu Punkt 3 (die 278 Doppelverzeichnisse), nicht zu einer Vorrangregel. Ebenso offen: 20 `chrony-*`-
Verzeichnisse (chrony-client, chrony-dhcp, chrony-dns …) — dieselbe Wildwuchs-Klasse.

## Nachprüfung meiner eigenen Behauptungen (2026-08-19)

Auf Nutzerwunsch: jede prüfbare Zahl aus den Abschnitten oben neu gemessen. **Keine war zum Zeitpunkt
der Messung falsch**, mehrere sind durch die zwischenzeitliche Arbeit **veraltet** — und der Audit hat
zwei echte Defekte gefunden, die keine Behauptung waren, sondern eine Lücke.

| Behauptung | damals | heute | Urteil |
|---|---|---|---|
| Template-Verzeichnisse | 5460 | 5460 | gilt |
| erreichbar über den Index | 2674 | 2908 | veraltet (Reparatur + Auflösung) |
| Unterstrich/Bindestrich-Paare | 278 | 278 | gilt |
| `chrony-*`-Verzeichnisse | 20 | 20 | gilt |
| leere Schemata | 169 | 165 | verändert (4 repariert) |
| davon erreichbar | 84 | **0** | behoben — genau der Zweck der Regel |
| Katalogrollen mit ≤2 Feldern | 19 | 17 | verändert (Reparaturen) |
| Rollen mit leerem `config_path` | 30 von 89 | **16 von 89** | stimmig: 14 gefüllt, wie berichtet |
| Pakete ohne Konfiguration | 3982 | 3982 | gilt |

**Eine Zahl war wirklich falsch** und ist bereits im Commit korrigiert: „datei-benannt schlägt paket-benannt
148 zu 7" — mit dem berichtigten Vergleich (letztes Punktsegment, also `server.host_name` = `host-name`)
sind es **101 zu 11**. Die Richtung hält, die Spanne war von einem fehlerhaften Test aufgebläht. Im
Dokument stand die falsche Zahl nie.

### [Widerspruchsfreiheit] Der Index bot Ziele an, die kein Renderer schreiben kann

  Beleg:   `/etc/bind` und `/etc/ovn-controller-vtep` standen als Ziel im Index — **Verzeichnisse**,
           während `/etc/bind/named.conf` im selben Register daneben liegt. Dazu
           `/etc/default/policyd-weight`.
  Problem: `template_render` schreibt **eine Datei**. Ein Verzeichnis als Ziel ist kein Beinahe-Treffer,
           sondern unschreibbar — dieselbe Fehlerklasse wie `/etc/restic` beim Resolver, nur durch die
           andere Tür hereingekommen: die Regel existierte in `main_config_path`, die Codec-Quelle des
           Index kannte sie nicht.
  Fix:     **eine** Regel in `bossman/services/template_gate.plausible_target`, angewandt auf alle drei
           Indexquellen. Verzeichnisse sind ohne Dateisystemzugriff erkennbar: existiert ein anderer
           bekannter Pfad unter `<pfad>/`, ist `<pfad>` das Verzeichnis. Grenze offen benannt: ein
           Verzeichnis ohne bekannte Kinder sieht wie eine Datei aus (`/etc/ovn-controller-vtep` bleibt).

  **Und mein erster Fix war zu streng** — die Zahl hat es verraten: er schloss auch die ancillary-Orte
  aus und nahm damit **626 Pfaden** ihren Editor. `/etc/default/chrony` *ist* eine bearbeitbare Datei mit
  einem Template, das genau sie rendert. `ANCILLARY_DIRS` beantwortet eine **andere** Frage — „welche
  Datei ist die *Haupt*konfiguration dieses Pakets" —, und die stellt der Index nicht. 3412 → **3349**
  (63 Verzeichnis-Ziele weg), nicht 2786.

### [Parsimonie] 14 Dateien haben zwei Türen: ein Snapin und einen generischen Editor

  Beleg:   Nutzerhinweis („bind ist ein snapin", „Netzplan wird mit dem Interface Modul bestückt"),
           gemessen gegen den Index:

           `/etc/bind/named.conf` → Snapin *BIND zones* **und** Template `bind9`
           `/etc/exports` → *NFS exports* und `exports` · `/etc/samba/smb.conf` → *Samba shares* und `samba`
           `/etc/dhcp/dhcpd.conf`, `/etc/cups/cupsd.conf`, `/etc/nginx/nginx.conf`,
           `/etc/apache2/apache2.conf`, `/etc/haproxy/haproxy.cfg`, `/etc/caddy/Caddyfile`,
           `/etc/traefik/traefik.yml`, `/etc/proftpd/proftpd.conf`, `/etc/crontab`,
           `/etc/logrotate.conf`, `/etc/bind/named.conf.options` — 14 insgesamt.
  Problem: Zwei Wege zum gleichen Ergebnis, und sie sind **nicht gleichwertig**: das Snapin kennt die
           Struktur (Zonen, Shares, vhosts, Drucker) und schreibt gezielt, der generische Editor rendert
           die **ganze Datei** aus einem Formular. Wer die falsche Tür nimmt, überschreibt die Arbeit der
           anderen — und nichts im UI sagt, welche die zuständige ist.
  Fix:     Nicht von mir zu entscheiden, weil es eine Produktfrage ist: entweder das Snapin ist für diese
           Pfade die einzige Tür (Template zurückziehen), oder der generische Editor bleibt als
           Notausgang und **sagt**, dass ein Snapin zuständig ist. Vorschlag: erste Variante für die
           strukturierten Formate (bind, samba, nginx, apache, cups, exports), zweite für die flachen
           (`/etc/crontab`, `/etc/logrotate.conf`), wo der generische Editor nichts kaputt macht.

---

## Nachtrag 2026-08-19 — die Codec-Registry (gemessen beim RedHat-Durchgang)

Beim Prüfen, welche RedHat-Pfade die Registry kennt, sind zwei Verstöße derselben Klasse aufgefallen.
Der erste ist behoben, der zweite ist der schwerere und ausdrücklich **noch offen**.

### [Identität] Behoben: 124 Registry-Schlüssel waren keine Pfade

  Beleg:   `configs/config_codecs.json` hatte 4473 Schlüssel, davon **124 nackte Dateinamen** —
           `haproxy.cfg`, `chrony.conf`, `vsftpd.conf`. Nachgeschlagen wird ausschließlich exakt:
           `codecs.get(path)` in [config_fields.py:80](../bossman/bossman/api/config_fields.py#L80).
  Problem: Für `/etc/haproxy/haproxy.cfg` **war** ein Codec bestimmt, und der Server hat die Datei
           trotzdem in den Freiform-/Template-Zweig geleitet — die Arbeit war nicht falsch, sondern
           unerreichbar. Und ein Basename ist mehrdeutig: `client.conf` benennt in dieser Registry vier
           Dateien mit vier verschiedenen Codecs, `config` fünf. Ein Basename-Lookup ist kein Kürzel,
           sondern ein Münzwurf — dieselbe Äquivokation, die aus dem Pfad→Template-Index schon entfernt
           wurde.
  Fix:     [`rekey_codec_registry.py`](../bossman/scripts/rekey_codec_registry.py) — 78 auf ihren einen
           echten Pfad umgeschlüsselt, 14 auf mehrere aufgefächert, 35 waren schon deckungsgleich.
           Verweigert und **als Daten hinterlegt** (`configs/config_codecs_unresolved.json`), nicht
           stillschweigend entschieden: 22 Konflikte (Pfad und Basename behaupten verschiedene Codecs),
           5 zu breit (`apparmor.d` hat 267 Ziele), 5 ohne jeden `/etc`-Pfad. Nackte Schlüssel 124 → 32,
           bekannte RedHat-Pfade 12 → 17. Zweiter Lauf: 0 verschoben.

### [Widerspruchsfreiheit] OFFEN: zwei Registries, 236-mal verschiedener Codec für dieselbe Datei

  Beleg:   `configs/config_codecs.json` (4496 Einträge, Server + gebündelt nach
           `/usr/share/agentic-mcp/configs`) und `internal/modules/config_codecs.json` (961, in den Agent
           **einkompiliert**). 869 Schlüssel in beiden, **236 mit verschiedenem Codec**:
           `/etc/dhcpcd.conf` keyvalue vs. none, `/etc/pulse/daemon.conf` ini vs. keyvalue.
           Richtung: 178-mal eingebettet spezifisch / kanonisch `none`, 2-mal umgekehrt, 56-mal **beide**
           spezifisch und verschieden.
  Problem: Der **Schreibweg** liest die eingebettete Registry
           ([codec_registry.go](../internal/modules/codec_registry.go)), der Anzeige-/Entscheidungsweg
           die gebündelte ([management.go:415](../internal/server/management.go#L415)). Also kann die UI
           „Freiform, ganze Datei rendern" anzeigen, während der Agent dieselbe Datei per Key mergt —
           zwei Ansichten mit widersprüchlichem Zustand für dasselbe Objekt, und das an der Stelle, wo
           geschrieben wird.
  Nicht:   Ein Sync in die eine Richtung. Die kanonische hatte diese 178 Codecs **nie** (geprüft bis
           HEAD~30), und die eingebettete trägt handgeprüfte Korrekturen (`sshd_config` ist
           space-separiert, `fstab`). Keine ist Teilmenge der anderen; ein Abgleich in beliebiger
           Richtung wäre Datenverlust.
  Fix:     Eine Registry mit einer begründeten Vorrangregel — und die Regel braucht einen
           **Beobachtungspunkt**, keine Vorliebe: für die 236 Streitfälle den ausgelieferten Dateitext
           holen und prüfen, ob der behauptete Codec **rundläuft** (parse → serialize → byte-gleich).
           Wer rundläuft, hat recht; wer nicht, ist widerlegt. `none` gewinnt nur, wenn kein Codec
           rundläuft. Das ist der nächste Block, nicht Teil dieses Durchgangs.

### Der Beobachtungspunkt existiert jetzt (Nachtrag zum offenen Befund)

[`codec_roundtrip_test.go`](../internal/modules/codec_roundtrip_test.go) misst, [`decide_codecs.py`](../bossman/scripts/decide_codecs.py) entscheidet. Der Codec einer Datei wird nicht mehr behauptet,
sondern am **ausgelieferten Text** widerlegt oder bestätigt — mit sechs Widerlegungen (keine Keys, nicht
stabil, Struktur zerhackt, falsches Kommentarzeichen, mehr Keys als aktive Zeilen, falscher Separator) und
zwei strukturellen Verweigerungen (geschweifte Verschachtelung, positionsabhängige Abschnitte wie
haproxys `global`/`defaults`).

Jede dieser acht Regeln kam aus einem **falschen Urteil im Lauf davor**, nicht aus dem Lehrbuch:
`ini` fand auf `httpd.conf` null Einstellungen und war damit trivial byte-identisch (wer nichts versteht,
ändert nichts); `keyvalue` behauptete 32 Einstellungen in `named.conf`, weil `options {` als Wert `{`
durchläuft; `sshd_config` meldete 59 Einstellungen bei 5 aktiven Zeilen, sobald das Kommentarzeichen falsch
war. Zwei meiner eigenen Messgrößen waren dabei ebenfalls falsch: `len(values)` zählte bei ini die
**Sektionen** (4 statt 24 bei `smb.conf`), und eine Prüfung auf „Schlüssel sieht wie ein Identifier aus"
verwarf `passdb backend` und `php_admin_value[error_log]` — beide legitim.

Erster Einsatz, 32 RedHat-Dateien: **18 Codec / 12 freiform / 2 kein Befund**. Gegen die Registry gehalten:
**12 bestehende Behauptungen bestätigt, 4 widerlegt** (`cupsd.conf` keyvalue → none bei 22 Blöcken,
`redis.conf` none → keyvalue, `smb.conf` none → ini byte-identisch, `sysconfig/memcached` none → keyvalue),
14 neu entschieden. Zwei der 22 Registry-Konflikte lösten sich dadurch von selbst (22 → 20). Und der seit
Längerem rote `TestGuessCodec` war kein Testfehler: die eingebettete Registry behauptete `ini` für
`/etc/nginx/nginx.conf` — 8 geschweifte Blöcke, widerlegt, korrigiert.

**Offen bleibt der Maßstab:** 827 der 961 eingebetteten Einträge tragen `confidence: inferred`, sind also
nie gemessen worden. Der Weg dahin ist derselbe wie bei RedHat: die `.deb`s holen (`_deb_config` existiert),
Text durch die Sonde, Urteil in die Registry — damit auch die 236 Widersprüche zwischen den beiden
Registries **einzeln belegt** aufgelöst werden statt per Vorrangregel.

### Der Widerspruch schrumpft belegt: 236 → 169

Die 234 streitigen Pfade wurden auf der Debian-Seite mit
[`deb_extract_configs.py`](../bossman/scripts/deb_extract_configs.py) nachgeschlagen (Gegenstück zur
RPM-Extraktion, `apt-get download` + `dpkg-deb -x`, nichts installiert). 74 davon existieren in Debian 12
main und liefern echten Text; der Rest stammt aus einem anderen Korpus (Ubuntu/universe) und bleibt
unentschieden — **gezählt, nicht weggelassen**.

Und damit die Frage beantwortet, die den ganzen Befund ausgelöst hat — welche Registry hat recht?

| | |
|---|---|
| kanonisch richtig | **26** |
| eingebettet richtig | **22** |
| **beide falsch** | **16** |
| kein Befund | 10 |

**Keine Vorrangregel hätte funktioniert.** Meine erste Eingebung („ein spezifischer Codec schlägt `none`")
wäre 26-mal falsch gewesen, die umgekehrte 22-mal, und in 16 Fällen ist keine der beiden Antworten richtig.
Genau deshalb wird jede Datei einzeln an ihrem Text entschieden. Ergebnis: Widersprüche **236 → 169**,
gemessene Einträge 0 → 44 (eingebettet) bzw. 55 (kanonisch).

Zwei weitere Fehlurteile fand erst dieser Lauf:
- `json` **liest** YAML (sein `parse` ist `yaml.Unmarshal`), **schreibt** aber JSON. Im Rundlauf ist es
  deshalb von `yaml` nicht unterscheidbar, und `/etc/docker/registry/config.yml` wäre als JSON
  zurückgeschrieben worden. Zusatzregel: `json` nur bei **striktem** JSON.
- `/etc/lighttpd/lighttpd.conf` ist auf EL geschweift (`$HTTP["url"] =~ … { }`) und auf Debian flach (dort
  in `conf-enabled/`-Fragmente zerlegt). Die Registry hat **einen** Datensatz pro Pfad, also kippte er bei
  jedem Lauf. Jetzt gewinnt die konservative Antwort (freiform kann nicht falsch mergen) und der Streit wird
  protokolliert. Der eigentliche Fix sind **Familien-Zweige pro Pfad**, wie sie `package_catalog.json`
  schon hat.

Offen bleibt der Maßstab: **783 der 961** eingebetteten Einträge sind weiter `inferred`.

### [Identität] Behoben: eine Quelle, eine erzeugte Projektion — Widersprüche 236 → 0

Zwei beschreibbare Kopien einer Tatsache lassen sich nicht durch Disziplin konsistent halten; eine muss
aufhören, Quelle zu sein. [`unify_codec_registry.py`](../bossman/scripts/unify_codec_registry.py) macht
`configs/config_codecs.json` zur einzigen Quelle und
`internal/modules/config_codecs.json` zu ihrer **erzeugten Projektion** (nur die drei Felder, die der Agent
liest: codec, separator, comment). [`codec_registry_projection_test.go`](../internal/modules/codec_registry_projection_test.go)
schlägt fehl, sobald die beiden auseinanderlaufen — die Fehlerklasse kann nicht durch Drift zurückkommen.

Der Zusammenschluss durfte nichts verlieren, und drei Versuche davon waren falsch, bevor gemessen wurde:

1. **Naive Projektion** hätte 238 Pfaden den Codec genommen, weil die kanonische Datei dort `none` sagt.
   Nachgemessen: **kein einziges** dieser `none` war gemessen — 138 unbelegte Vorgaben hätten 138
   Behauptungen gelöscht. Jetzt weicht ein **ungemessenes** `none` einer konkreten Angabe (übernommen als
   `inferred`, also mit offener Messschuld); ein **gemessenes** gewinnt und die widersprechende Angabe wird
   als erledigt protokolliert.
2. **Alle nackten Basennamen verwerfen** hätte 91 brauchbare Rückfälle für 9 Münzwürfe geopfert. Der Agent
   fragt erst den Pfad, dann den Basename — so bekommt ein unbekanntes `/etc/chrony/chrony.conf` überhaupt
   eine Grammatik. Verworfen werden nur die **mehrdeutigen** (`client.conf` = vier Dateien über ini/yaml/none,
   `config` = 25); die übrigen wurden als `kind: basename-fallback` **benannt** statt heimlich aufgelöst.
3. **Basennamen in Pfade auflösen** löschte 86 Rückfälle unbemerkt: die Pfade existierten schon, der Import
   meldete „already", und der Rückfall selbst war weg.

Nebenbei fiel `TestGuessCodec` wieder rot — und wieder zu Recht: ohne den mehrdeutigen Basename
`daemon.json` antwortete der Pfad-Datensatz `ini` für eine **JSON**-Datei. Vier Pfade behaupteten `ini` für
`.json`/`.toml`/`.yaml`, alle mit `confidence: high` und ohne Messung. Die Endung ist intrinsische Evidenz
(dieselbe Art wie die strict-JSON-Widerlegung) und entscheidet.

| | vorher | jetzt |
|---|---|---|
| Widersprüche zwischen den Registries | 236 | **0** |
| Einträge, die der Agent trägt | 961 (878 nutzbar) | **1733** |
| Größe der Agent-Datei | 323 KB | **154 KB** |
| Herkunft in der Quelle | — | 55 gemessen, 217 importiert, 4 per Endung, 4301 ungemessen |

Live geprüft: `smb.conf` → ini-Merge (vorher Ganzdatei-Template), `nginx.conf` → Template (vorher falscher
ini-Merge im Agent), `daemon.json` → json, `sshd_config` → keyvalue.

**Damit bleibt genau eine offene Front:** 4301 Einträge sind ungemessen. Der Weg ist gebaut und erprobt
(`deb_extract_configs.py` / `rh_extract_configs.py` → Sonde → `decide_codecs.py`); es fehlt der Korpus-Lauf
über alle Pakete.

---

## Nachtrag 2026-08-19 (RedHat-Durchgang, Teil 2)

### [Identität] OFFEN: `config_directives.json` hat zwei Leser mit zwei Annahmen über ihre Form

  Beleg:   [`config_schema.py:105`](../bossman/bossman/services/config_schema.py#L105) packt eine umhüllte
           Form aus (`entry.get("directives") if isinstance(...) else entry`), während
           [`wizard_seed.py:168`](../bossman/bossman/services/wizard_seed.py#L168) den Direktivennamen
           **direkt** in `directives[path]` sucht.
  Problem: Dieselbe Datei darf laut einem Leser `{"directives": {...}, "source": …}` sein und laut dem
           anderen nicht — wer die umhüllte Form schreibt, bricht die Wizard-Defaults still, denn dort wäre
           `directives` einfach eine Direktive namens „directives". Zwei Formen für eine Datei sind zwei
           Dinge unter einem Namen.
  Fix:     Eine Form festlegen (die flache, weil sie geschrieben wird) und den unbenutzten Auspack-Zweig
           entfernen — oder beide Leser auf die umhüllte umstellen. Bis dahin **nicht** hineinschreiben:
           Provenienz liegt daneben in `configs/config_directives_sources.json`
           ([`rh_mine_directives.py`](../bossman/scripts/rh_mine_directives.py)).

### Direktiven für RedHat: erst der Zwilling, dann das Modell

Eine Direktive gehört zur **Software**, nicht zur Distribution — Apache liest `ServerRoot`, ob die Datei
`/etc/apache2/apache2.conf` oder `/etc/httpd/conf/httpd.conf` heißt. Diese Zwillingsbeziehung steht seit
Langem kuriert im Katalog (`families.debian.config_path` ↔ `families.redhat.config_path`) und ist in diesem
Durchgang gegen die RPM-Inhalte **verifiziert** worden. Also erbt der RedHat-Pfad die Direktiven seines
Zwillings — exakt, kostenlos, ohne Modellaufruf.

Gemessen, bevor gebaut: 16 Rollen haben wirklich verschiedene Pfade je Familie, aber nur **3** ihrer
Debian-Zwillinge haben heute überhaupt Direktiven (`mariadb` 22, `vsftpd` 35, `sysstat` 8). Der Erbschaftspass
ist also klein — er wächst aber automatisch mit jeder Debian-Seite, die gemint wird. Die übrigen 13 Pfade
gehen an qwen35b über die bestehende Maschinerie (`_resolve_man` + `_web_docs` → `mine_one`, JSON-Schema als
Grammatik server-seitig erzwungen); neu ist hier nur die **Auswahl**, welche Pfade überhaupt gemint werden,
und die Aufzeichnung, woher jede Antwort kommt.

### [Gültige Ableitung] Die Direktiven-Herkunft wurde nie geprüft — und lieferte die falsche Software

  Beleg:   `/etc/redis/redis.conf` wurde zu 18 Direktiven namens `SSL_verify_mode`,
           `sentinels_cnx_timeout`, `on_connect` gemint — den Optionen des **Perl-Moduls** `Redis(3pm)`,
           weil die Man-Page-Suche zum Paketnamen „redis" diese Seite fand. Deckung der 41 Schlüssel, die
           die ausgelieferte Datei setzt: **0 %**.
  Problem: Niemand hat gefragt, ob die geholte Dokumentation überhaupt von dieser Datei handelt. Ein
           Katalog voll selbstsicherer Einträge für die falsche Software ist schlechter als ein leerer —
           der Einstellungs-Editor würde Optionen anbieten, die der Dienst nie gehört hat.
  Fix:     Die Schlüsselliste der ausgelieferten Datei ist der **Fingerabdruck** der richtigen
           Dokumentation: echte Doku zu einer Konfigurationsdatei nennt ihre Direktiven, fremde nicht.
           `doc_is_about()` verlangt, dass mindestens ein Fünftel (und wenigstens drei) der Schlüssel im
           Text vorkommen, sonst wird die Web-Quelle versucht und andernfalls **nichts** geschrieben.
           Zusätzlich: `MAN_PAGE_FOR` für Dateien, deren Seite anders heißt — postfix' Parameter stehen in
           `postconf(5)`, eine `main.cf(5)` existiert nicht, weshalb dort nur 16 KB Webseiten gefunden
           wurden und 15 von 32 Schlüsseln beschrieben waren.

**Die Deckungsprüfung ist der Beobachtungspunkt, der beides fand** — und die Zahlen, die sie liefert, sind
das Abnahmekriterium für diesen Katalog: `chrony.conf`, `dnsmasq.conf`, `snmpd.conf`, `sysconfig/memcached`
je **100 %**, `vsftpd` 92 %, `pure-ftpd` 86 %, `sysstat` 86 % — und die widerlegten wurden verworfen und neu
gemint, statt sie als „gefüllt" zu zählen. Vererbung vom Zwilling ist exakt für das, was sie abdeckt, aber
sie **verspricht keine Deckung**: `mariadb-server.cnf` erbt 22 gültige Direktiven und trifft damit nur 1 von
4 Schlüsseln der EL-Datei.

### [Identität] Behoben: zwei Auflöser für „welches Template rendert diese Datei"

  Beleg:   `config_fields._template_for_path` löste über den **Basename** auf (minus `.conf`/`.cfg`), dann
           über einen Paketnamen aus dem Codec-Eintrag — während `template_index` dieselbe Frage über
           `meta.json`/`target_path` beantwortet.
  Problem: Sichtbar geworden, sobald eine zweite Distribution existiert:
           `/etc/named.conf` (EL) bekam das **Debian**-Template, dessen `meta.json` sagt, dass es
           `/etc/bind/named.conf` rendert — eine fremde Distribution über die eigene Datei geschrieben.
           `/etc/httpd/conf/httpd.conf` bekam **gar nichts**, obwohl `apache2-redhat` genau diese Datei
           rendert; nur heißt kein Verzeichnis „httpd.conf". Zwei Auflöser für eine Frage, und der zweite
           gab die falsche Antwort.
  Fix:     `config_fields` fragt jetzt den Index. Live geprüft: EL-`httpd.conf` → `apache2-redhat`
           (Zeuge rpm), EL-`named.conf` → `bind9-redhat`, Debian-`/etc/bind/named.conf` → sein eigenes.

### [Ausgeschlossenes Drittes] OFFEN: gleicher Pfad, zwei Distributionen, ein Template

  Beleg:   `/etc/caddy/Caddyfile` heißt auf beiden Familien gleich, hat aber verschiedenen Inhalt. Der Index
           meldet den Streit ordentlich als Konflikt (`chosen: caddy` aus dem Katalog, `also: caddy-redhat`
           aus `template-meta`) — **entscheidet** ihn aber zugunsten des Katalogs, also Debian.
  Problem: Auf einem RedHat-Host würde `Caddyfile` aus dem Debian-Template gerendert. Der Index ist
           host-unabhängig (Autorenansicht) und kann die Familie nicht kennen; die Auswahl gehört daher an
           die Stelle, die den Host kennt.
  Fix:     Familien-Zweige pro Pfad — dasselbe Muster, das `package_catalog.json` schon hat — und eine
           host-seitige Auswahl, die den familien-passenden Kandidaten nimmt. Datenlage bisher: von den
           ersten drei RedHat-Templates kollidiert **eines**; die Zahl wächst mit dem laufenden Durchgang
           (`nginx.conf`, `lighttpd.conf`, `proftpd.conf` heißen ebenfalls auf beiden Seiten gleich).

### [Gültige Ableitung] Das Urteil eines Modells ist eine Behauptung, kein Befund

Über vier Prüfläufe (Hermes/laguna, dieselben 14 Templates) hat der unabhängige Prüfer acht Aussagen
gemacht. Jede wurde **nachgerechnet, bevor gehandelt wurde** — und das war nicht Formalie:

| Aussage | geprüft |
|---|---|
| `freeradius`: Backslashes in Kommentaren verfälscht (`(i.e. \\)` → `(i.e. \\n)`) | **wahr** |
| `nftables`: Platzhalter in auskommentierter Zeile — wirkungslos | **wahr**, betraf 3 Templates / 40 Felder |
| `collectd`: else-Zweig aus dem falschen Plugin-Block | **wahr** |
| `cups`: `Option deny,allow` statt `Order deny,allow` | **wahr** |
| `apache2`: Prosa (`# Relax access …`) als aktive Direktive gerendert | **wahr** — der schwerste Fund |
| `exim`: verschachteltes Escaping (`{{ '{{' }}` erneut escapt) | **wahr** |
| `proftpd`: eingefügtes Wort „In" in einem Kommentar | **erfunden** — die Zeichenfolge existiert im Template nicht |
| `apache2` zweimal FAITHFUL, dann DEFECTIVE — bei **unveränderter** Datei | **widersprüchlich** |

**Sechs von acht trafen zu**, und die sechs haben Defekte gefunden, die alle meine Invarianten passiert
hatten. Aber ein Urteil ist nicht reproduzierbar (dieselbe Datei, drei Läufe, zwei Ergebnisse) und kann
frei erfunden sein. Daraus die Arbeitsregel:

> **Der Prüfer zeigt, er entscheidet nicht.** Jede Aussage muss auf etwas Nachrechenbares zeigen — dann
> wird sie geprüft, und wenn sie zutrifft, wird sie zu einer **mechanischen Invariante**, damit dieselbe
> Fehlerklasse nie wieder ein Modellurteil braucht. Was nicht nachrechenbar formuliert ist, ist unbrauchbar.

Deshalb sind aus den sechs wahren Aussagen sechs Invarianten geworden
([`verify_templates.py`](../bossman/scripts/verify_templates.py)) und vier Reparaturen, die **im Generator**
laufen — nicht sechs Notizen.

---

## Identität, eine Ebene höher: wer beschreibt eigentlich welche Datei?

Die Modellprüfung war der Anfang; die schwereren Fehler lagen in der **Zuordnung** von Katalogen und
Templates zu Pfaden. Alle vier Befunde unten sind ohne Modell entschieden — durch Messung an den Bytes,
die die Pakete wirklich ausliefern.

### 1. Nackte Basisnamen im Direktivenkatalog

`config_directives.json` trug **91 Basisnamen** neben 1063 echten Pfaden, und `catalog_for_path` **mischt**
Basename- und Pfadtreffer. Nützlich, wenn der Name eine Datei meint (`NetworkManager.conf`); giftig, wenn er
mehrere meint: der nackte Katalog `config` mit 29 Direktiven wurde in **zwanzig** unverwandte Dateien
gemischt — `/etc/dehydrated/config`, `/etc/gridengine/config`, `/etc/selinux/config`, `/etc/w3m/config` —
und **keiner** der fünf messbaren dieser zwanzig enthält einen einzigen dieser 29 Schlüssel.

[`resolve_directive_basenames.py`](../bossman/scripts/resolve_directive_basenames.py) entscheidet nach Beweis:
34 Namen meinen genau einen Pfad (umbenannt), 3 sind **Zwillingspaare** (Debian ↔ EL, an *beide* Pfade
gehängt — `/etc/vsftpd.conf` hätte sonst die 51 Direktiven verloren, die es nur über den Merge hatte), 2 sind
unattribuierbar und wandern nach `unattributed:<name>`: der Text bleibt erhalten, aber kein Basename-Lookup
erreicht ihn mehr. Ergebnis 1154 → 1117 Schlüssel, 22986 → 22471 Direktiven (Duplikate beim Merge).

### 2. Katalog ohne Schreibweg

40 Pfade tragen **1114 Direktiven**, obwohl ihr Codec am Byte als `none` gemessen ist — der Agent hat dort
keinen Per-Schlüssel-Schreibweg. `/config-fields` verzweigt korrekt (Template-Zweig), die **UI aber schrieb
die Messung um**: `format: e.codec === 'none' ? 'keyvalue' : e.codec` in beiden gpedit-Editoren. Damit war
für cupsd.conf, lvm.conf, lftp.conf ein Merge angeboten, den kein Writer ausführen kann — im OU-Editor sogar
als *Policy*, die gespeichert wird, an ihrem Scope gewinnt und dann ins Leere greift. Jetzt bleibt die
Messung stehen, die Zeilen entfallen (`writesPerKey`), und die Verweigerung nennt ihren Grund
(`noPerKeyReason`).

### 3. Fremde Kataloge — und warum Abwesenheit kein Beweis ist

[`find_foreign_catalogs.py`](../bossman/scripts/find_foreign_catalogs.py): 26 Pfade, 683 Direktiven, von deren
Schlüsseln **keiner** in der eigenen ausgelieferten Datei vorkommt (`/etc/shells` trägt sssd-Schlüssel,
`/etc/mime.types` uWSGI-Optionen, `/etc/sudoers` Timeshift-Variablen). Sechs Wege, auf denen der einfache
Test lügt, mussten erst raus: Stub-Datei, dotted keys, Wert-statt-Zeilenanfang, Doppelpunkt-Namespace
(`cache:enable`), Schreibstil (`poll_interval_max_sec` vs `PollIntervalMaxSec`) und minimal ausgelieferte
Dateien mit großem Direktivenraum (squid, fwupd). Die **positive** Probe — welche andere Datei benutzt diese
Schlüssel? — bestätigt nur 2 von 26, und beide sind Fehltreffer (ein Zwilling, ein Zufall auf 8 generischen
Namen). Also: **gemeldet, nichts gelöscht.** Der Korpus kann Fremdheit hier nicht beweisen.

### 4. Der Index widersprach seinen eigenen Artefakten

`build_template_index` band nach **Namen** (Quelle 1 Rollenname, Quelle 2 Codec-Key) und stellte die
aufgezeichnete Tatsache (`meta.json target_path`) dahinter. Gemessen am Live-Index: **203 von 3611 Bindungen**
nannten ein Template, das in seiner eigenen `meta.json` einen **anderen** Pfad aufzeichnet —
`/etc/ansible/hosts` war an `hosts` gebunden (Ziel `/etc/hosts`), und da Configure die **ganze** Datei
schreibt, hätte der Knopf die Maschinen-hosts über ein Ansible-Inventar geschrieben. `/etc/cups/cupsd.conf`
war an `cups` gebunden, dessen `template.j2` neun Zeilen cups-**snmp.conf** sind.

Zwei Regeln, beide mechanisch: ein Template wird **nicht** an einen Pfad gebunden, von dem es selbst sagt, es
rendere ihn nicht (216 Verweigerungen, jede mit Grund im `conflicts`-Feld); und eine **bezeugte Aufzeichnung
schlägt eine Namensbindung** (`witness: deb|rpm|corpus-text`) — außer die Aufzeichnung nennt eine Familie und
es wurde keine erfragt, sonst bekäme ein Debian-Host EL-Dateien (`/etc/caddy/Caddyfile`).

Damit die Aufzeichnung überhaupt existiert, fragt
[`attribute_templates_by_text.py`](../bossman/scripts/attribute_templates_by_text.py) jedes der 4809
Templates ohne `target_path`, aus **welcher** ausgelieferten Datei sein Literaltext stammt (invertierter
Zeilenindex über 8206 Korpusdateien). Der Test muss **symmetrisch** sein: einseitig setzte er `argus-client`
auf `/etc/smbldap-tools/smbldap.conf`, weil sie sich sieben Zeilen GPL-Kopf teilen — ein Template deckt
seine Quelldatei auch ab, ein Lizenzkopf nicht. 69 Templates sind so belegt platziert, 4674 haben zu wenig
unterscheidenden Text (der Korpus ist RedHat; Debian-only-Dateien kann er nicht platzieren).

### 5. Was die Datei über sich selbst sagt

Ein Editor kann vollständig korrekt sein und trotzdem eine Falle: `/etc/munin/munin.conf` ist parsbar, hat
14 Direktiven — und sagt in Zeile 3 *„Please don't edit this example config file. Create and edit
/etc/munin/munin-conf.d/…"*. Ein dort gesetzter Wert wird beim nächsten Generatorlauf verworfen, die Drift
kommt zurück, und **nichts** in der UI hat je gesagt warum. Das ist ein Verstoß gegen den zureichenden Grund,
nicht gegen die Grammatik.

[`find_generated_files.py`](../bossman/scripts/find_generated_files.py) liest die ersten 15 Zeilen jeder
Korpusdatei. Die Regel muss sich auf **diese Datei** beziehen, sonst trifft sie das Falsche — von 139
Phrasentreffern reden 54 von etwas anderem: `RSS.header` von *Berichten*, `sysconfig/gsisshd` von
*Schlüsseln*, `sites-available/soh` von *Requests*, `libuser.conf` von *einem Abschnitt*, `irqbalance` vom
*Verhalten*. Verlangt sind beide Hälften in derselben Zeile — Phrase **und** Selbstbezug („this file", der
eigene Basisname) —, und Lizenzklauseln („DO NOT ALTER OR REMOVE COPYRIGHT NOTICES") sind ausgenommen.
Bleiben **84 Dateien**, jede mit Zeilennummer und wörtlichem Zitat.

Ausgegeben wird das als **Zitat, nicht als Verbot**: `GET /config-generated` (Karte für Listen),
`machine_written` auf jeder `/config-fields`-Antwort, und in beiden gpedit-Editoren eine Zeile über der
Tabelle. „DO NOT EDIT THIS FILE" und „edit this *example* config, create one in conf.d/" verlangen
verschiedene Handlungen — welche, weiß nur die Datei. Im OU-Editor ist der Hinweis schärfer nötig als am
Host: eine Policy wird gespeichert, gewinnt an ihrem Scope und wird bei jedem Generatorlauf überschrieben,
d. h. die Konsole meldete dauerhaft Drift, die sie nicht beheben kann.

Nebenbei geschlossen: `/config-fields` hatte **keinen einzigen Test**, obwohl jeder Feldeditor darüber
auflöst. [`test_config_fields_api.py`](../bossman/tests/test_config_fields_api.py) pinnt jetzt alle vier
Schreibzustände (codec / template / freeform / unknown) plus den Hinweis — inklusive der beiden Defekte, die
das Fehlen des Tests möglich gemacht hat (`"none"` ist truthy; Template-Auflösung per Basisname).

### 6. Der ganze Korpus, gegen die eigenen Regeln gemessen

Bis hierher waren die Codec-Verdikte aus Teilläufen zusammengesetzt. Ein Durchlauf über **alle** 8163
Korpusdateien (40815 Proben, 19 s in Go) hat 277 Behauptungen widerlegt, die nie geprüft worden waren:
243× `xml`, 20× `yaml`, 12× `json`, je einmal `keyvalue`/`ini` — jeweils zu `none`. Der Grund ist keine
Feinheit: der flache `xml`-Codec würde bei ImageMagicks `policy.xml` **157 Zeilen** verlieren, bei
`type-apple.xml` **1172**. Diese Dateien boten einen Editor an, der sie zerstört hätte.

**Ein Shebang ist noch kein Programm.** Die Probe hat „ausführbar" bisher als *ein* Signal gemeldet, und
das trifft die falschen Dateien: `/etc/makepkg.conf` beginnt mit `#!/hint/bash` — einem reinen
Editor-Hinweis — und enthält 26 Zuweisungen ohne jeden Kontrollfluss. Jetzt berichtet die Messung
Kontrollfluss, Shebang und Zuweisungen **getrennt**, und die Entscheidung fällt dort, wo alle anderen
fallen. Gemessene Trennung, mit Abstand:

| Datei | Zuweisungen / aktive Zeilen | | |
|---|---|---|---|
| `/etc/kea/keactrl.conf` | 18/18 | 1.00 | Env-Datei |
| `/etc/sysconfig/raid-check` | 7/7 | 1.00 | Env-Datei |
| `/etc/makepkg.conf` | 26/35 | 0.74 | Env-Datei (Array-Werte über Fortsetzungszeilen) |
| `/etc/ppp/ip-up` | 3/8 | 0.38 | **Skript** — pppd führt es aus |
| `/etc/apcupsd/onbattery` | 2/10 | 0.20 | **Skript** — setzt eine Nachricht, ruft `wall` |

Eine erste Fassung fragte nur „gibt es überhaupt Zuweisungen?" und rettete damit jedes dieser Skripte:
apcupsds fünf Event-Handler, beide ppp-Hooks, gdms `PreSession/Default` (ein Shebang, sechs Kommentare, **eine**
Zuweisung — Verhältnis 1.0 und trotzdem ein Skript, daher zusätzlich mindestens drei Zuweisungen für eine
„Liste").

**Und die Enthaltung war zu breit.** Ein Skript wird nie als Konfigurationsdatei *angelegt* — aber wo die
Registry für eines **schon** einen Per-Schlüssel-Codec behauptete, ließ die Enthaltung die falsche Behauptung
stehen: `/etc/mc/edit.indent.rc` (Shebang + `case`, mcs externer Formatierer) trug `ini` und 46 Direktiven,
`/etc/cron.daily/etckeeper` trug `keyvalue`. Korrigieren gibt keine Schreibstrategie — es nimmt eine, die es
nie gab.

### 7. 147 Templates, die ihr eigenes Sample nicht rendern

`TestConfigTemplatesRenderWithSample` war rot, und zwar seit langem: **147 von 5474** Templates scheitern
gegen ihre eigene `sample.json` — 55 parsen nicht, 89 sterben beim Rendern (`isinstance is not callable`:
das Modell hat Python-Builtins in Jinja geschrieben), 3 rendern leer. Ein roter Gesamttest sagt nichts über
die Änderung, die vor einem liegt, also ist die bekannte Menge jetzt ein **Datensatz**
(`configs/template_render_broken.json`) und der Test eine **Ratsche**: nichts außerhalb der Liste darf
scheitern, und nichts innerhalb darf gelistet bleiben, sobald es rendert.

Derselbe Datensatz speist die serverseitige Sperre (`template_configures` → `False`, weil *gemessen*, nicht
unbekannt). Der Index verliert damit **62 Bindungen**, deren „Configure"-Knopf ausschließlich eine
Fehlermeldung erzeugen konnte. Der Lookup musste zwei Orte kennen — im Repo liegt der Datensatz neben dem
Template-Verzeichnis, im Container daneben in `/app/configs` —, denn die erste Fassung fand ihn im Test und
in Produktion nicht, und ließ dort alle 147 durch.

---

## Der Kehraus: das Modell schlägt **Regeln** vor, nicht Urteile

Bis hierher lief jede Prüfung Datei für Datei — 804 Modellaussagen über 157 Pfade, davon 309 widerlegt und
470 unentschieden, und jeder echte Fund musste hinterher von Hand zu einer Regel werden. Das ist die
Tretmühle: **die Klassen wiederholen sich, die Dateien sind nur der Ort, an dem sie auftauchen.**

[`sweep_invariants.py`](../bossman/scripts/sweep_invariants.py) stellt daher die andere Frage. Das Modell
bekommt das Schema der Artefaktklasse, die **schon vorhandenen** Prüfungen und eine Stichprobe echter
Datensätze — und muss mit **Invarianten** antworten, jede mit einem Python-Prädikat, das *wahr* ist, wenn ein
Datensatz sie verletzt. Danach führt der Harnisch jedes Prädikat über **alle** Datensätze der Klasse aus:

| Treffer | Bedeutung |
|---|---|
| 0 | die Klasse kommt hier nicht vor — aufgeschrieben, nicht implementiert |
| eine Handvoll | echter Fund → Beispiele ansehen, dann Linter-Regel oder Test |
| über die Hälfte | die Regel hat das Format missverstanden und widerlegt sich selbst |

Modelle: **qwen3.5-35b** über Hermes auf dem geteilten lokalen Endpunkt (ein Prozess, seriell, fortsetzbar,
Fortschritt geloggt) und danach **poolside/laguna-s-2.1** über OpenRouter als zweite Meinung — ein anderes
Modell hat andere blinde Flecken, und es hat vier Klassen gefunden, die qwen nicht sah.

### Zwei Fehler im Prüfer, die der Kehraus an sich selbst fand

1. **Ein Prädikat mit Comprehension scheiterte an `NameError`**, weil Namen aus dem `locals`-Mapping von
   `eval` im Rumpf einer Comprehension unsichtbar sind. Ein *korrektes* Prädikat wurde als „broken" gemeldet.
   Nach der Korrektur (Datensatz in `globals`) melden **acht von elf** Prädikaten Funde, wo vorher „sauber"
   stand — die drei sauberen Klassen waren ein Artefakt meines Prüfers.
2. **Ein Prädikat, das nichts erfüllen kann**, zählte null Verstöße — also genau wie eine saubere Klasse
   (`codec not in ['yaml','none'] and codec not in ['ini','keyvalue','xml','json']`). Jetzt muss das Modell
   ein `example_record` mitliefern, das seine *eigene* Regel trifft; wer daran scheitert, gilt als *vacuous*.

Dazu ein **Gedächtnis**: jedes Urteil (`refuted` / `implemented` / `open` mit Begründung) steht im
Zustandsfile und wird in jeden späteren Prompt gespiegelt. Sonst schlagen zwei Modelle dieselbe plausible
Klasse zweimal vor, und die Tretmühle beginnt von vorn.

### Was dabei herauskam

**Direktiven** (22471 Datensätze): 1980 Einträge mit `min == max == 0` — eine Spanne, die keinen Wert
zulässt, davon 531 auf Booleans und 191 auf Enums; die vorhandene `min > max`-Regel sah das nie, weil
`0 > 0` falsch ist. 234 Defaults „not set"/„empty"/„n/a" (wo die Datei vorlag, war ein solcher Wert nur **5
von 167** Mal wirklich belegt — `auto`, `disabled`, `unset` blieben bewusst stehen). 60 Spannen auf
`bool`/`enum`/`list`. 56 `int`-Felder mit Bruchzahl-Default → Typ `number`, denn chrony nimmt wirklich
`maxslewrate 83333.333`. **Widerlegt:** „values ohne enum" (311) — bei `bool` tragen die Werte die
Schreibform (`Yes`/`No` statt `true`), und aus `values=['en']` ein Dropdown zu machen würde jede andere
Sprache verbieten.

**Codecs** (11561): 149 Einträge behaupteten `sections: true` bei flachem Codec — die Konsole zeigt das dem
Bediener als „grouped, e.g. `[section]`". Die erste Reparatur war in der *anderen* Richtung falsch (sie
erzwang `sections: true` für alle 211 `ini`-Einträge, die *false* sagten) und die Daten haben sie widerlegt:
`sections` beschreibt die **Datei**, nicht die Grammatik — 1697 von 1908 `ini`-Dateien haben wirklich
`[section]`-Köpfe, die 211 anderen sagten die Wahrheit. **Widerlegt:** „Verzeichnis ohne Endung" (2845
Treffer, aber nur 19 sind wirklich Verzeichnisse — und alle 19 tragen längst `codec: none`).

**Templates** (5474): **2561 Felder in 341 Templates** werden angeboten, obwohl ihr Name im Body nirgends
vorkommt (`acme.sh` bietet 69 und platziert 5; `sshd` rendert eine PAM-Datei und beschreibt `sshd_config`).
`/config-fields` hält sie jetzt zurück **und nennt die Zahl** — vorher füllte ein Bediener sie aus und der
Ganzdatei-Render verwarf sie wortlos. Dazu 994 Schema-Reparaturen
([`lint_template_schemas.py`](../bossman/scripts/lint_template_schemas.py)) und 27 doppelte Enum-Werte.

Die schärfste Lehre steckt in einem Rückschritt, den die **Render-Ratsche** gefangen hat: ich hatte
`sample.json` an den deklarierten Typ angepasst — und damit `anymeal`, `frr` und `munin-node.conf` sofort
zerstört (`Can't use Getitem on None`). Das Sample ist mit dem Body erzeugt und rendert nachweislich; der
Typ ist das, was der Batch geraten hat. **Also wird der Typ korrigiert, nie das Sample.**

### 8. Die andere Hälfte derselben Lücke: Werte, die das Formular nicht liefern kann

`/config-fields` hält seit dem Kehraus die 2561 Felder zurück, die ein Template gar nicht platziert. Die
Gegenrichtung war offen: der **Body liest** eine Variable, die **kein Feld anbietet** — der Bediener kann sie
nicht setzen, und der Ganzdatei-Render schreibt sie leer.

Die Zahl des Kehrauses war dafür unbrauchbar. Sein Prädikat suchte jeden Schemaschlüssel als Regex im Body
und fand 1206 Treffer — mitgezählt waren Schleifenvariablen (`{% for host in hosts %}`), `{% set %}`-Namen,
Makro-Argumente und `loop.index`. Gemessen mit **Jinjas eigenem Parser**
([`find_unsettable_variables.py`](../bossman/scripts/find_unsettable_variables.py),
`meta.find_undeclared_variables`) sind es **182 Templates mit 523 Variablen**; 4714 sind sauber, 428 kann
jinja2 nicht parsen (gonja rendert sie — ein Befund, der von der Wahl des Parsers abhängt, ist kein Befund
über die Daten). Nicht gezählt wird außerdem, was das Template selbst auffängt: `{{ workers | default(4) }}`
braucht kein Feld, und ein Schemaschlüssel `tls.enabled` macht `tls` sehr wohl setzbar.

Die Verteilung entscheidet die Handlung:

- **142 Templates fehlen ein bis zwei Werte** — das Formular deckt den Rest, also wird die **Zahl gemeldet**
  (`unsettable` auf jeder `/config-fields`-Antwort, plus eine Zeile im Editor). Live: `/etc/frr/frr.conf`
  meldet `bgp_as`.
- **24 brauchen mehr, als sie anbieten** — `gimprc` 75 Werte gegen 7 Felder, `prometheus_alertmanager` 15
  gegen 2. Dort würde der Render eine überwiegend leere Konfiguration über eine funktionierende schreiben,
  also wird der Editor **nicht angeboten** (`template_configures → False`, weil gemessen).

---

## Die Debian-Seite: 3038 Pfade, die nie gemessen waren

Die RedHat-Seite war fertig, die Debian-Ernte auf Wunsch gestoppt. Wieder aufgenommen und durchgelaufen:
**6455 Dateien aus 3886 Paketen** (598 nicht herunterladbar — verschwundene Versionen), Korpus jetzt 6999
Dateien. Ein Durchlauf der Probe (6909 Dateien, 34545 Ansprüche) und die Registry sieht anders aus:

| | vorher | nachher |
|---|---|---|
| Einträge | 11561 | **14599** |
| davon an den Bytes gemessen | 7283 (63 %) | **10984 (75 %)** |
| Projektion, die der Agent trägt | 5347 | **7286** |

**290 Behauptungen hat die Datei widerlegt** — 131× `none → keyvalue` (ein Editor, den es nicht gab), 68×
`keyvalue → none`, 33× `ini → none`, 30× `ini → keyvalue`.

### Ein Codec pro Pfad ist zu wenig

1605 Pfade liegen in **beiden** Korpora, und **33 messen unterschiedlich** — nicht weil eine Messung falsch
ist, sondern weil die Distributionen für denselben Pfad **verschiedenen Inhalt** ausliefern:
`/etc/logrotate.conf` und `/etc/lighttpd/lighttpd.conf` sind auf Debian flach und auf EL verschachtelt,
`/etc/dnsmasq.conf` umgekehrt. Ein Datensatz pro Pfad ist damit für eine Familie zwangsläufig falsch, und der
Schreibweg handelt danach.

Also Zweige pro Familie, wie der Paketkatalog sie längst hat: `by_family: {debian: {...}, redhat: {...}}`
neben einem **konservativen** Top-Level (`none` — ein Ganzdatei-Template kann nicht falsch mergen, ein
Codec-Merge in die falsche Blockstruktur schon). `/config-fields` kennt die Familie aus den Fakten des Hosts
und bevorzugt den Zweig. Live geprüft an `/etc/logrotate.conf`: ohne Familie `freeform`, mit
`family=debian` `codec/keyvalue`, mit `family=redhat` wieder `freeform` — kein Ausleihen der fremden Messung.

### Und die Projektions-Wache hat sich bezahlt

Nach dem Debian-Lauf schlug `TestEmbeddedRegistryMatchesItsSource` an: `/etc/clustershell/groups.conf` stand
im Agenten als `ini`, in der Quelle als `none`. Ursache ist `decide_codecs --registry both` — die Agenten-
Registry ist eine **generierte Projektion** der kanonischen, und wer sie direkt schreibt, lässt beide
auseinanderlaufen. Genau der Zustand, den „eine Quelle, eine Projektion" beseitigen sollte. `both` ist jetzt
im Werkzeug als Falle benannt: kanonisch schreiben, dann `unify_codec_registry.py` regeneriert.

### 9. Die Manpages: was sie entscheiden können und was nicht

Die Ernte lädt jedes Paket herunter und warf bisher alles außerhalb von `/etc` weg — inklusive der
Dokumentation. [`deb_harvest_manpages.py`](../bossman/scripts/deb_harvest_manpages.py) behält Sektion 5, 8
und 1: **10545 Seiten aus 4079 Paketen**, offline und exakt.

**Was damit entscheidbar wurde:** ob ein Katalogschlüssel eine echte Direktive ist. Aber nur mit
**Kalibrierung**, und die ist der ganze Trick — „steht nicht in der Manpage" bedeutet nur etwas, wenn diese
Seite die richtige ist. Dokumentiert das Paket ≥ 60 % der Schlüssel eines Katalogs, beschreibt es
offensichtlich diese Datei (`postfix` → `main.cf`: 372 Schlüssel, 99 % dokumentiert), und die fehlenden sind
dann Beweis. Dokumentiert es 5 %, ist es die falsche Quelle und sagt über keinen Schlüssel etwas. Ergebnis:
**137 Kataloge kalibriert, 209 Schlüssel entfernt**, die *weder* in der Manpage *noch* in der ausgelieferten
Datei vorkommen — zwei unabhängige Negative auf einem Dokument, das sich für diese Datei bewährt hat. 308
Kataloge zu schwach gedeckt, 116 Pakete ohne Manpage, 553 Pfade ohne bekanntes Paket: alles Enthaltungen.

**Was der Test nicht sieht**, und er hat es selbst gesagt: `/etc/pam.d/sshd` gilt als „89 Schlüssel, 100 %
dokumentiert" — weil openssh-server auch `sshd_config(5)` mitbringt. Die Schlüssel sind echt, nur an der
falschen **Datei** des richtigen Pakets. Das beantwortet `find_foreign_catalogs` aus den Bytes. Zwei Fragen,
zwei Werkzeuge, keines vertritt das andere.

**Und wofür die Manpages nicht taugen:** Beschreibungen. Roff-Absätze hängen nicht zuverlässig am Namen
darüber; von drei extrahierten Sätzen waren zwei Fragmente aus dem Nachbarabsatz (`lvm.conf` →
„configuration parameter."). Der Kommentarblock **in der Datei** klang besser und war es nicht: 11 Treffer,
davon mindestens zwei über eine *andere* Einstellung (`openssl.cnf`s `default_days` als „Extensions to add to
a CRL.", das ist der Zeilenkommentar von `crl_extensions`). Etwa jede sechste falsch — für Text, an dem ein
Bediener ablesen soll, was ein Daemon tut, zu viel. **Beide Läufe sind zurückgenommen**, das Skript bleibt
als Messung, die das belegt, und die 410 leeren Beschreibungen bleiben offen für den Mining-Weg mit
`doc_is_about`-Gate — ein Modell *mit* Prüfung, keine Heuristik über Nachbarzeilen.

### 10. Die leeren Beschreibungen: Modell **mit** Gate schlägt Heuristik

Die 410 Felder ohne Beschreibung sind der Beweis, dass die Reihenfolge zählt. Meine beiden offline-Heuristiken
haben versagt (Manpage-Absätze: 2 von 3 Fragmente; Kommentarblock: jede sechste über eine andere Einstellung).
Derselbe Rohstoff, durch den **Miner mit `doc_is_about`-Gate** geschickt, liefert brauchbare Sätze:

| Datei | Direktiven | ohne Beschreibung | Quelle laut Aufzeichnung |
|---|---|---|---|
| `/etc/lvm/lvm.conf` | 134 | 82 → **0** | eigene Kommentare (1134 Zeilen) |
| `/etc/fwupd/fwupd.conf` | 62 | 62 → **0** | `fwupd.conf.5` (13962 Bytes) |
| `/etc/smbnetfs.conf` | 32 | 17 → **0** | eigene Kommentare (315 Zeilen) |
| `/etc/lftp.conf` | 174 | 72 → **65** | eigene Kommentare (63 Zeilen) |

Insgesamt **410 → 242**. Damit die Manpages dabei überhaupt greifen, musste zweierlei nachgezogen werden:
die Seiten kommen jetzt **offline aus dem geernteten Korpus** (kein Lookup kann mehr auf die falsche Software
landen, wie „redis" auf das Perl-Modul `Redis(3pm)`), und wo Doku und Config in **verschiedenen Paketen einer
Quelle** liegen — `smb.conf(5)` in `samba`, nicht in `samba-common`; `sysctl.d(5)` in `systemd`, nicht in
`systemd-udev` — fällt die Suche auf das Basispaket zurück. Das Gate entscheidet weiterhin: bei `lvm.conf` hat
es die Manpage **abgelehnt** und auf die Kommentare der Datei umgeschaltet.

**Und ein Fehler von mir, den nur der Vorher-Vergleich zeigte:** `--remine` hat den Katalog *ersetzt*.
`/etc/lftp.conf` fiel damit von 165 auf 20 Direktiven — seine Doppelpunkt-Einstellungen (`cache:enable`,
`bmk:save-passwords`) sind echt und früher gegen die Datei geprüft, aber ein Mine über 63 Kommentarzeilen
sieht nur einen Bruchteil. 145 echte Einstellungen gegen 20 Beschreibungen ist ein schlechter Handel. Der
Miner **merged** jetzt pro Schlüssel (die frische Messung gewinnt, unerwähnte Schlüssel überleben), und die
verlorenen sind zurückgeholt.

### 11. Drei Dokumentationsquellen, in dieser Reihenfolge

Der Miner nimmt jetzt: **die geerntete Paketseite** (offline, exakt, kann nicht über fremde Software sein) →
**die zwei öffentlichen Spiegel** per direkter URL (`man7.org/linux/man-pages/man5/<name>.5.html`,
`manpages.debian.org/<name>`) → **die Kommentare der Datei selbst**. Die Metasuche fällt raus
(`QUALIFY_NO_SEARXNG=1`): mit drei Manpage-Quellen bringt sie nur Latenz und Treffer über die falsche Software.

Die Spiegel brauchen den **Proxy** (`http://proxy.example.internal:80`), und `no_proxy` muss `llm.example.internal`
enthalten — dort liegen Modell *und* SearXNG.

**Ein Fehlschluss von mir, den es wert ist aufzuschreiben:** ein Lauf stand 24 Minuten, ich fragte den
Modell-Endpunkt ab, sah `is_processing: false` und schaltete die Online-Rückfälle ab, „weil sie hängen". Der
Endpunkt hat **vier Slots** — ich hatte Slot 0 gelesen, und Slot 1 hat die ganze Zeit gerechnet. Der Lauf war
langsam, nicht blockiert. Die Abschaltung ist zurückgenommen; was bleibt, ist die Reihenfolge, und die steht
aus eigenem Recht (das Paket, das die Datei ausliefert, kann nicht über fremde Software sprechen).

**Ergebnis über beide Batches:** 410 → **217** leere Beschreibungen. Von den 18 Pfaden des letzten Laufs
7 gemint, 11 ehrlich verweigert — „Dokumentation ist nicht über diese Datei (0 % ihrer Schlüssel) und die
Datei hat 4 Kommentarzeilen" ist eine Antwort, keine Panne. Und die frisch geminten Direktiven trugen wieder
dieselben Defektklassen wie eh und je: der Linter hat 149 Nullspannen, 111 Spannen auf `bool`/`enum`/`list`
und 7 Enum-Defaults außerhalb ihrer Werte entfernt — deshalb läuft er nach jedem Mining.

### 12. Textattribution über beide Korpora: 308 Templates platziert

Mit 13525 Korpusdateien statt 8206 findet die Literaltext-Attribution **308** Templates (vorher 69) — der
Index bindet jetzt 479 Pfade über eine **aufgezeichnete Messung** statt über den Namen, und wächst dabei von
3375 auf 3533 Pfade.

Eine Fehlerklasse musste dafür erst geschlossen werden: **Init-Skripte sind fast identische Rahmen** (LSB-
Header, `start|stop|restart`-case), also passt ein daraus gebautes Template auf jedes andere, und die
„unterscheidenden" Zeilen sind das gemeinsame Gerüst. Der erste Lauf platzierte `canna` auf
`/etc/init.d/snmptrapfmt` (100 % gegen einen Verfolger bei 50 %), `cyborg-api` auf
`/etc/init.d/cloudkitty-api`, `openafs-fileserver` auf `/etc/init.d/krb5-admin-server`.

Die Regel: **ein enger Verfolger braucht die Zustimmung des Namens.** Wo beide Pfade dieselbe Software nennen,
kann das Geschwisterproblem nicht auftreten (`owhttpd` → `/etc/init.d/owhttpd` bei 100 % gegen 82 % ist
richtig); wo nicht, und eine andere Datei liegt innerhalb von 30 %, enthält sich die Attribution. Das kostet
auch richtige Treffer — `nordugrid-arc-hed` → `/etc/init.d/arched` ist korrekt und fällt weg, weil nichts hier
es zeigen kann. Danach: 0 Platzierungen ohne Namensbezug bei engem Verfolger, gegen 22 vorher.

Nebenbei: der Bericht wird jetzt **auch ohne `--write`** geschrieben. Ein Trockenlauf, dessen Zahlen man nicht
nachrechnen kann, ist eine halbe Messung — und die ersten 16 Zeilen einer 317er-Liste sagen nichts über den
Rest.
