# Zielbestimmung yolo-man

> Der Nordstern des Projekts: was yolo-man ist, welche Logik durchgängig gilt,
> und woran sich jede Design-Entscheidung messen lassen muss.

## Mission

**yolo-man** ist ein einheitliches, KI-natives System für **Deployment und
Monitoring** von Linux-Infrastruktur — ein Ansible-Nachfolger, der über eine
schlanke Vertrauenskette (**Bossman** → **Selecta** → **Duppy**) arbeitet: der
Controller pusht, der Agent wählt nie nach außen, eine einzige Firewall-Regel
genügt.

## Grundprinzipien (durchgängige Logik)

1. **JSON ist die kanonische interne Repräsentation** für alles: der
   Ausführungsvertrag (JSON-in / JSON-out), die Persistenz (JSONB in Postgres,
   TimescaleDB für Zeitreihen) und der Plan-Cache. Alles andere ist Oberfläche
   darüber.

2. **NestedText ist das Hauptformat für Menschen** — das primäre Autoren- und
   Bedienformat für Pläne, `tools.d`-Tasks und Modul-Sidecars. NestedText hat
   keine implizite Typisierung, kein Quoting, kein Escaping ("Norway-Problem"
   ausgeschlossen). JSON ist das Maschinen-/Speicherformat; NestedText das, was
   ein Mensch schreibt und liest.

3. **Multi-Format-Import:** yolo-man akzeptiert Pläne aus **NestedText (primär),
   YAML, JSON** sowie **Chef, Puppet und Salt** und konvertiert jeden
   **deterministisch** in den kanonischen JSON-Plan — damit die KI so wenig wie
   möglich arbeiten muss. KI-Übersetzung ist die Ausnahme (nur wo keine
   deterministische Abbildung existiert), nicht die Regel.

4. **Kanonische Dokumenten-Datenbank für Pläne:** alle Pläne liegen in *einer*
   JSONB-Tabelle, **präfix-keyed** nach Herkunftssystem
   (`ansible` / `salt` / `puppet` / `chef`), versioniert und
   content-addressiert als Cache. Die Quelltexte bleiben als Import- und
   Diff-Grundlage erhalten; die Datenbank ist die Wahrheit, die Dateien sind
   Import.

5. **Modulvertrag JSON-in / JSON-out** (wie Ansible): jedes Modul bekommt ein
   JSON-Objekt an Argumenten und liefert genau ein JSON-Ergebnisobjekt
   (`changed`, `msg`, `data`). Native Go-Module für `ansible.builtin`,
   sandboxed **Starlark** für Collections (Logik als Code, nicht als Daten).

6. **Monitoring ist Teil desselben Systems:** Duppys und Selectas liefern alle
   Zustände als **JSON** über ihre REST-APIs; Custom-Script-Output wird vom
   Duppy **großzügig** (best-effort, bewusst lockerer als CheckMK) nach JSON
   konvertiert — Status kommt aus dem Exit-Code, die Meldung bleibt immer
   erhalten, Perfdata wird opportunistisch geparst. **Nie Datenverlust** durch
   Syntax-Strenge.

7. **Ein System für alles Wichtige:** Deployment und Monitoring teilen sich
   Controller, Scope-/GPO-Logik, Vertrauenskette und Datenmodell. Es gibt nicht
   zwei Werkzeuge, sondern eines.

## Ist/Soll-Konsistenzmatrix

Stand der Prüfung (drei Code-Audits). ✓ = konsistent umgesetzt,
◑ = teilweise, ✗ = Lücke.

| # | Ziel | Stand | Beleg / Lücke |
|---|------|:---:|---------------|
| 1 | JSON-Basis, JSON-in/out; Formate NT/YAML/JSON/Chef/Puppet/Salt | ◑ | JSON-in/out durchgängig (`internal/modules/module.go`, `agent_client.call_tool`); NT + YAML → gemeinsames `build_plan_from_raw`. JSON nur inzidentell; **kein** Chef/Puppet/Salt-Parser (nur Prosa-Äquivalenzen). |
| 2 | Alle Formate → JSON, in DB als Cache | ◑ | Konvertierung nach JSON vorhanden; Pläne aber nur als Dateien + In-Memory-Katalog (`services/catalog.py`). **Keine `plans`-Tabelle.** |
| 3 | Monitoring-Daten JSON über Duppy/Selecta-APIs | ✓ | Vollständig JSON über REST → TimescaleDB-Hypertables (`metrics`, `service_state_history`, `connection_events`). |
| 4 | Custom-Script-Output vom Duppy nach JSON, großzügig | ✓ | `internal/checks/checks.go` — best-effort, lockerer als CheckMK; Meldung immer erhalten, kein Datenverlust. |
| 5 | Ein System für Deployment + Monitoring | ✓ | Ein Controller kompiliert+pusht Thresholds und wertet Status aus; gemeinsamer Scope/GPO (`compiler.py`, `gpo.py`, `monitoring.py`). |
| 6 | Dokumenten-DB für Pläne mit Präfix | ✗ | `orchestration_plan_versions` ist ein JSONB-Plan-Store, aber **ohne Herkunfts-Präfix**; file-basierte Pläne liegen außerhalb der DB. |

### Zentrale Inkonsistenz

Es existieren **zwei getrennte Plan-Welten**:

- **file-basiert** — `plans_dir`-Pläne (YAML/NestedText), nur im Speicher
  gecacht, kein DB-Eintrag außer dem Ausführungs-Audit (`plan_runs`);
- **DB-basiert** — `orchestration_plans` / `orchestration_plan_versions`
  (JSONB, versioniert), ein höheres Rollen-/Deployment-Konstrukt.

Die Vision (Prinzipien 2 + 4) verlangt *einen* kanonischen, präfix-keyed
JSON-Plan-Store. Das ist die erste zu schließende Lücke.

## Roadmap (Reihenfolge)

1. **Kanonischer Plan-Store** — eine präfix-keyed JSONB-`plans`-Tabelle als
   Wahrheit + Cache; Importer für die bestehenden `plans_dir`-Pläne
   (`prefix=ansible`). *(erledigt: `services/plan_store.py`, Migration
   `a3d7f0c2b915`, `scripts/import_plans_dir.py`.)*
2. **JSON first-class** als Eingabeformat (eigener `source_format`, `.json` im
   Loader). *(Store akzeptiert `source_format=json`; `.json` im Datei-Loader
   noch offen.)*
3. **Deterministische Fremdformat-Parser** → kanonisches Plan-Dict, je ein
   neuer Präfix. *(erledigt)* **Salt** (`services/salt_parser.py`),
   **Chef** (`services/chef_parser.py`, deklarative Resource-Teilmenge),
   **Puppet** (`services/puppet_parser.py`, flache Resource-Deklarationen;
   Klassen/Bedingungen/Variablen werden abgelehnt). Alle drei erzeugen das
   kanonische Plan-Dict und speichern über `store_plan(prefix=…)`.
4. **Präfix-Guard verallgemeinern** (`plan_loader.ANSIBLE_PREFIX`), sobald ein
   Runtime Fremdmodule ausführen kann.
5. **`plans_dir` ablösen** — Katalog und Runner vollständig auf den Store
   umstellen; Dateien nur noch Autoren-Import.
6. **Starlark-Runtime (Block G3)** — Voraussetzung, dass übersetzte Collection-
   und Fremdmodule tatsächlich *laufen* (heute nur validiert).
