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
