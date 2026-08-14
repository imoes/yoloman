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

1. **UI-Client vereinheitlichen** (klein, kein API-Bruch): einen Client, ein Typsatz,
   `resource-node` umstellen, Duplikat löschen.
2. **Registry einführen** (`services/resources/__init__.py`) mit kind→Klasse und
   deren Eigenheiten als Attribute.
3. **36 → 6 Routen** zusammenlegen; die alten Pfade bleiben identisch, also kein
   Bruch für Aufrufer.
4. **Vertragstest** über die Registry (Punkt 4 oben).
