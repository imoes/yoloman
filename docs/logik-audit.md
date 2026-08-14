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

### Rangfolge

1. `vanished` sichtbar und behandelbar machen (unsichtbarer Zustand → Fehlbedienung).
2. Schwellwert/Begründung an der Messung (falsche Ruhe bei WARN/CRIT).
3. Service-Checks in den Checks-Tab falten (ein Ort pro Aufgabe).
4. Benennung vereinheitlichen (zieht sich durch alle Screens, daher zuletzt und
   in einem Zug).
