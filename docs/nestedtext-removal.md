# NestedText streichen — Ansible-Syntax als einziges Autorenformat

> Eigener Plan (die PXE- und Lego-Pläne bleiben unberührt). Fremdformat-**Importe** (Salt/Puppet/Chef)
> bleiben erhalten — siehe `docs/orchestration-import.md`.

## Kontext

Das System trug zwei Autorenformate: NestedText und Ansible-Task-Syntax. Zwei Grammatiken heißen zwei
Parser, zwei Serialisierer und zwei Fehlerquellen — und nur eine davon kann jemand außerhalb dieses Systems
lesen. NT wird gestrichen, Ansible-Syntax bleibt.

Beim Aufräumen kamen drei echte Fehler heraus, die genau der Doppelspurigkeit anzulasten sind:

1. **NT als internes Zwischenformat.** `runbook_exec`, `scheduler` und `rollout` serialisierten den
   kanonischen JSON-Doc nach NT und parsten ihn zurück — nur um an den Validator zu kommen.
2. **Gespeicherte Rollen verloren ihre Identität.** `parse_data` erkannte eine Role nur am Autoren-Key
   `role:`, den `to_dict()` nie schreibt. Ein aus der DB geladenes Role-Doc kam als *Runbook* zurück — ohne
   Checks und Notification-Routes, und am „das ist eine Role, kein Runbook"-Guard vorbei.
3. **Der `${}`-Shim zerstörte Shell-Argumente.** Er schrieb *jedes* `$wort` in *jedem* String um:
   `echo $HOME` → harter Fehler `'HOME' is undefined`, `awk "{print $2}"` wurde **still** zu
   `awk "{print 2}"`. Shell-Argumente sind das Häufigste in einem Runbook. Nachweislich 0× genutzt in
   48 gespeicherten Runbooks.

## Was wir mit NT aufgeben (Begründung der umgekehrten Entscheidung)

`docs/nt-format.md` und `docs/nestedtext-playbooks.md` (443 Zeilen) waren die Begründung *für* NT und werden
gelöscht — ihr Kern gehört aber festgehalten, denn die Nachteile von YAML sind echt und bleiben:

- **Implizites Typing („Norway problem").** In YAML wird `no` zu `false`, `0755` zu einer Dezimalzahl,
  `1.10` verliert die Null, und `@ % :` erzwingen Quoting. NT hatte das nicht — jedes Blatt war ein String.
- **Der Preis, den wir zahlen:** ein File-Mode muss `"0755"` heißen, ein Boolean-artiger String muss
  gequotet werden. Das ist derselbe Footgun, mit dem Ansible seit Jahren lebt.
- **Warum wir ihn trotzdem zahlen:** Ansible-Kompatibilität ist das Ziel (`docs/orchestration-import.md`:
  10/10 Task-Dateien einer echten Upstream-Rolle). Ein Format, das nur dieses System lesen kann, kauft
  Typsicherheit gegen Interoperabilität — und Interoperabilität war der Punkt. Zwei Formate parallel zu
  pflegen hat außerdem die drei oben genannten Fehler *verursacht*.
- **Wo NTs Idee weiterlebt:** die Typ-Coercion sitzt jetzt an der Modulgrenze (`_as_bool`, die schmale
  `key=value`-Coercion im Ansible-Parser, das Argspec des Moduls auf dem Agenten) statt im Dateiformat —
  dieselbe Stelle, an der Ansible sie auch macht.

## Teil A — Autorenformat (gebaut, Backend + UI grün)

1250+ Backend-Tests grün, UI baut. Umgesetzt:

- `nt_runbook.py` ist jetzt das kanonische **Doc-Modell**, kein NT-Parser. `parse_data(dict)` existierte
  schon; `parse_document`/NT-Eingang sind weg. Role-Erkennung akzeptiert zusätzlich `kind: role` (Fehler 2).
- Die drei NT-Round-Trips ersetzt (Fehler 1). `nt_convert` hat nur noch die doc-shaped-YAML-Ansicht.
- API/MCP/CLI ohne `nt`-Felder: `SaveRunbookBody{playbook|doc}`, `LintBody{playbook}`,
  `runbook_nt` → `runbook_playbook`; `yolo-man convert` wandelt YAML↔JSON statt YAML↔NT.
- **`role:` ist jetzt Ansible-Syntax**: `{role, tasks, monitoring.checks?, notifications.routes?}` in
  `parse_playbook` — dieselbe Art Erweiterung, die `targets:` schon war.
- `plan_store`/`plan_loader` ohne `nestedtext`; `nt_plan_loader.py` gelöscht; Importe unberührt.
- UI: der Add-Roles-Wizard **erzeugte NT im Browser** (handgeschriebener Serialisierer) → baut jetzt ein
  Objekt und dumpt es mit dem bereits vorhandenen `js-yaml`. NT-Umschalter aus Plan-Library und
  Runbook-Editor entfernt; `ntBlock` war toter Code.
- Tests umgestellt: die Engine-Tests laufen jetzt über `parse_playbook`, also den echten Produktionspfad.
- **`nt_engine`/`nt_vars`/`nt_compile` bleiben** — die heißen nur `nt_*`, parsen aber kein NestedText
  (Engine, Variablen-Substitution, Role-Compiler).

### Rest von Teil A — erledigt

1. ✅ **`bossman/tests/test_nt_vars.py`** (~10 Tests auf dem Shim) → Jinja-Äquivalente: `$host`/`${host}` →
   `{{ host }}`, `${x:-d}` → `{{ x | default('d', true) }}`, `${x:?msg}` → `{{ x | mandatory('msg') }}`.
   **Plus neuer Regressionstest** für Fehler 3: `echo $HOME` und `awk "{print $2}"` gehen unverändert durch.
2. ✅ **Drei Reste:** `services/plan_store.py` `_FORMAT_BY_EXT` mappt noch `.nt → "nestedtext"` (**aktiver
   Code** — eine `.nt`-Datei würde als nicht mehr unterstütztes Format klassifiziert); `api/plans.py` und
   `db/models.py` nennen `nestedtext` in Kommentar/Docstring.
3. ✅ **Doku:** `docs/nt-format.md` (267 Z.) und `docs/nestedtext-playbooks.md` (176 Z.) spezifizieren ein
   entferntes Format → löschen. Erwähnungen bereinigen in `docs/ui-parity.md`, `docs/resource-protocol.md`,
   `docs/backlog.md`, `docs/ui-workspaces.md`, `docs/zielbestimmung.md`, `README.md`. `CODE_CARD.md` bekommt
   den Satz „Ansible-Task-Syntax ist das einzige Autorenformat" plus die drei Fehler als Begründung.
4. ✅ Volle Suite (1265 grün) + UI-Build, deployed, committed (`08cb867e`).

## Teil B — Stand: checks.d konvertiert, modules.d wartet auf root

**Erledigt (1431 Dateien).** `configs/checks.d/*.nt` → `*.yaml`, verifiziert *durch den Reader* statt
bytegleich: `_coerce_metadata(alt) == _coerce_metadata(neu)`, also „identisch, wie das System es liest".
`writes` und jedes `required` sind echte Booleans; `default`/`type`/`choices` bleiben Strings, weil der
Reader sie bewusst so lässt und das Modul an seiner eigenen Grenze coerct — sie hier zu typisieren wäre eine
Verhaltensänderung im Gewand einer Formatänderung. Lint: 1431/1431 parsen, laden durch
`load_metadata`, Katalog lädt weiter 1430 Checks (die 1431. Datei ist `mysql.provision.yaml`, ein Rezept).
Leser umgestellt: `checks_library` (Pfad + Parser + Schreibpfad), `provisioning`, `api/checks`,
`module_library.metadata_path`.

**Offen: die 623 `.nt` in `configs/modules.d/` gehören `root`** (vom Container geschrieben), Löschen braucht
also sudo. Sie sind beweisbar redundant — pro Datei geprüft: `nt == stringify(yaml)`, 623/623 —, die
typrichtigen `.yaml`-Originale liegen daneben. **Nicht mehr dringend**, weil `metadata_path` jetzt `.yaml`
bevorzugt statt `.nt`: die Reihenfolge war vorher umgekehrt und hat still Typen gekostet (`true` als String
`"true"`, `8080` als `"8080"` bei Modulen, deren Argspec echte Bools/Ints hatte). Damit sind die
root-Dateien inert; ihr Löschen ist reine Aufräumarbeit:
`sudo find configs/modules.d -name '*.nt' -delete`.

Ein **Datenfund**, bewusst nicht mitgefixt (eine Formatkonvertierung, die auch Inhalte ändert, ist als
Formatkonvertierung nicht mehr verifizierbar): 3 Optionen deklarieren `type: str` statt `string`, was
`_PARAM_TYPES` gar nicht kennt — `check_plugin` (`item`, `force_format`) und `checkmk_local` (`item`).

## Teil B — der Ansatz (Referenz; Stand siehe oben)

Das sind **keine** Runbooks, sondern Metadaten (`name`/`fqcn`/`options`): 1431 in `configs/checks.d/`,
~620 in `configs/modules.d/`. Die Konvertierung ist `nestedtext.loads()` → `yaml.safe_dump()` und damit
**beweisbar** korrekt statt stichprobenhaft geprüft — deshalb ausdrücklich *kein* LLM-Lauf: ein still
verändertes `type:`/`default:` bricht ein Modul erst zur Laufzeit, und verifizieren könnte man einen
LLM-Lauf nur, indem man ihn mit genau dieser deterministischen Ausgabe vergleicht.

5. **Konverter** `bossman/scripts/convert_sidecars_to_yaml.py` — erst `scripts/convert_sidecars_nt.py`
   ansehen (existiert, evtl. Gegenrichtung) und wiederverwenden statt neu bauen. Pro Datei: laden → dumpen →
   **`nestedtext.loads(alt) == yaml.safe_load(neu)` assertieren** → `.yaml` schreiben, `.nt` löschen.
   Abweichung ⇒ Datei unangetastet lassen und im Report melden, nie still übernehmen. `--dry-run` zeigt die
   Bilanz vorher.
6. **9 Leser** auf `.yaml` (`services/module_library.py`, `checks_library.py`, `monitoring.py`,
   `provisioning.py`, `checkmk_translation.py`, `api/checks.py`, …) und die **7 Generatoren** auf
   `.yaml`-Ausgabe (`translate_active_checks.py`, `retranslate_checks.py`, `describe_checks.py`,
   `categorize_checks.py`, `classify_check_execution.py`, `generate_check_docs.py`).
7. **Go-Agent: keine Code-Arbeit nötig** — `internal/starmodules/loader.go` liest `.nt`/`.yaml`/`.yml`
   bereits. Erst *nach* der Konvertierung `.nt` aus der Kandidatenliste nehmen (Reihenfolge zählt) und den
   gebündelten Katalog neu packen (`scripts/build-agent-deb.sh` → `/usr/share/agentic-mcp/configs`).
8. **Zuletzt** `nestedtext>=3.7` aus `bossman/pyproject.toml` — erst wenn nichts mehr NT liest. Dass die
   Abhängigkeit heute noch steht, ist genau der Grund für Teil B.

## Kritische Dateien

| Datei | Änderung |
|---|---|
| `bossman/tests/test_nt_vars.py` | Shim-Tests → Jinja; **neuer** Shell-`$`-Regressionstest |
| `bossman/bossman/services/plan_store.py` | `_FORMAT_BY_EXT`: `.nt` raus (aktiver Code) |
| `bossman/bossman/api/plans.py`, `db/models.py` | Kommentar/Docstring |
| `docs/nt-format.md`, `docs/nestedtext-playbooks.md` | **löschen** |
| `CODE_CARD.md` + 5 docs + `README.md` | Autorenformat-Satz, Erwähnungen |
| `bossman/scripts/convert_sidecars_to_yaml.py` | **neu** (oder `convert_sidecars_nt.py` erweitern) |
| `services/{module_library,checks_library,monitoring,provisioning,checkmk_translation}.py` | Sidecar-Endung |
| `bossman/scripts/*checks*.py` (7 Generatoren) | `.yaml` schreiben |
| `internal/starmodules/loader.go` | `.nt` aus der Kandidatenliste — **nach** Schritt 5 |
| `bossman/pyproject.toml` | `nestedtext` raus — **zuletzt** |

Wiederverwenden, nicht neu bauen: `parse_data` (Validator, war schon format-agnostisch), `parse_playbook`
(Ansible-Fläche inkl. neuem `role:`), `doc_to_playbook` (Render-Richtung), `js-yaml` (schon in der UI),
`retranslate_checks.py` (Muster für Batch-Skripte mit Resume/Report).

## Verifikation

1. `cd bossman && BOSSMAN_DATABASE_URL=postgresql+asyncpg://bossman:bossman@localhost:55433/bossman
   .venv-host/bin/python -m pytest -q` → grün (Basis: 1250 grün; 11 NT-Fixtures wurden umgestellt).
2. `cd bossman-ui && npx ng build` → grün, keine `nestedtext`-Treffer mehr in `src/`.
3. `grep -rn "nestedtext\|NestedText" bossman/bossman/ bossman-ui/src/ docs/` → nach Teil A nur noch die
   Sidecar-Leser, nach Teil B leer.
4. **Rollen-Regression (Fehler 2):** eine Role speichern, neu laden, `kind == "role"` prüfen — und dass
   Scheduler/Rollout sie weiterhin als Role ablehnen statt sie als Runbook zu fahren.
5. **Sidecars:** danach Check-Katalog-Zahl unverändert (**1431**), `bossman/bin/starlark-check` grün, ein
   Check läuft end-to-end gegen einen Host, Agent neu gebaut und gebündelter Katalog geladen.
6. `docker compose up -d --build`; ein Runbook aus der UI dry-run + apply (der Pfad, der vorher über NT lief).
