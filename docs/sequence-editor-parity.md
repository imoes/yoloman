# Sequence-Editor: Variablen, SCCM-Parität, Blockly-Übernahme

> Eigener Plan. Ergänzt `docs/ui-workspaces.md` (dort Slice 3 = der Tree), überschreibt ihn nicht.

## Kontext

Der Sequence-Tree aus Slice 3 läuft, aber beim Benutzen fallen sechs Dinge auf. Zwei davon sind echte
Fehler, nicht Geschmack:

- **Variablen fehlen komplett.** Eine Rolle ist ohne ihre Variablen nicht bedienbar — genau die Sache, die
  in `ansible-manager` schon gebaut ist (`VariablesPanel.js`, 226 Z.) und beim Portieren übersehen wurde.
- **Die Facts-Liste in der UI passt nicht zu dem, was der Agent liefert.** Die kopierte
  `ansibleFacts.js` listet `ansible_facts['distribution']` (die moderne Namespace-Form). Der Agent
  (`internal/modules/setup.go`) liefert aber **flache** Namen: 18 × `ansible_*` (darunter
  `ansible_board_vendor`, `ansible_bios_vendor`, `ansible_product_serial`) und davon gespiegelt
  `yoloman_*`. Eine aus dem Panel gezogene Variable **löst also nicht auf**.

## Warum das Layout von SCCM abweicht (die Frage aus dem Review)

Ehrliche Antwort: Ich habe das Layout nicht bewusst geändert — ich habe eine **Teilmenge** gebaut.
`docs/ui-workspaces.md:145` fordert *„a step is any Resource — a Role, a Module task, a Check, a
Config/Template resource, a container, or a nested Sequence"*. Gebaut ist nur **Gruppe + Modul-Task**; die
Icons (🎭 Role, ✅ Check) werden aus dem *Modulnamen geraten* (`glyph()`), es gibt keine echten Step-Typen.
Und die SCCM-Affordanzen aus dem Screenshot fehlen ganz — die standen auch nicht im Plan, gehören aber dazu:

| SCCM (Screenshot) | Status |
|---|---|
| Toolbar `Add ▾` / `Remove` / ↑ / ↓ | fehlt (nur Drag & Drop + ×) |
| Suchfeld mit **Search Within**: Step Name, Step Description, Step Type, Group Name, Group Description, **Variable Name**, **Conditions**, Other Contents | fehlt komplett |
| **Filter By**: Continue On Error, Has Conditions | fehlt |
| Status-Icon pro Step, Gruppen als Ordner | ✅ da |

Dass SCCM „Variable Name" und „Conditions" *durchsuchbar* macht, ist genau der Beleg für Punkt 1: dort sind
Variablen und Bedingungen erstklassige Bestandteile einer Sequenz, nicht Beiwerk.

## SCCM-Modell: Sequence baut das Image, Rolle verknüpft den Run

Der Operator: *„bei sccm ist es so, dass man eine sequence für ein Image baut und dann eine Rolle mit dem run
verknüpft."* Das passt auf das, was schon existiert, und muss nur verbunden werden:

- **Sequence** = die geordnete Prozedur (Task Sequence) → serialisiert zum Ansible-Playbook, läuft auf dem
  Go-Runner. Baut z. B. ein Disk-Image (siehe `docs/pxe-baremetal-imaging.md`).
- **Rolle** = was ein *Typ Host* sein soll, inkl. Monitoring/Notifications → wird an OU/Gruppe/Host
  gebunden. Seit Teil A der NT-Entfernung ist eine Rolle Ansible-Syntax mit `role:`-Envelope.
- **Verknüpfung** = die Rolle referenziert den Sequence-Run. `import_tasks`/`include_role` → unser
  `runbook`-Step existiert dafür bereits (`_ROLE_CALL_KEYS` in `services/ansible_playbook.py`).

## Arbeitsschritte

1. **Variablen-Panel** (der Kern). `VariablesPanel.js` (React, 226 Z.) → Angular-Komponente unter
   `features/runbooks/sequence/`. Zeigt Rollen-/Sequence-Parameter (`parameters:` im Doc), die Facts und
   `register`-Variablen; Einfügen per Klick/Drag in Argument-Felder und in den `when:`-Builder
   (`varInsertion.js` + `conditionParser.js` sind schon portiert und framework-frei).
2. **Facts-Liste korrigieren** — `ansibleFacts.js` gegen die Wahrheit aus `internal/modules/setup.go`
   stellen: die 18 flachen `ansible_*` **und** die `yoloman_*`-Spiegel, jeweils mit Beschreibung, in zwei
   Gruppen. Prüfen, ob wir zusätzlich einen echten `ansible_facts`-Dict-Alias im Agenten anbieten wollen —
   importierte Rollen nutzen `ansible_facts['x']`, und Import ist ein Kernversprechen.
3. **Eingabefelder verkleinern** — `shared/param-form` verletzt `docs/design-philosophy.md:79-88`: es zeigt
   *alle* Felder in voller Material-Höhe. Soll: nur was der Operator liefern **muss**, Defaults hinter einer
   *Advanced*-Disclosure, kompakte Controls statt `mat-form-field`-Chrome („Deference — chrome is minimal").
4. **SCCM-Parität im Tree** — Toolbar (`Add ▾`/Remove/↑/↓), Suchfeld mit *Search Within*-Scopes (inkl.
   Variable Name + Conditions) und *Filter By* (Continue On Error = `ignore_errors`, Has Conditions =
   `when`). Beides sind Projektionen des Dokuments, also reine View-Logik.
5. **Echte Step-Typen** — Role / Check / Config / nested Sequence als Step-Arten statt aus dem Modulnamen
   geraten (`glyph()`); das ist die offene Hälfte von `docs/ui-workspaces.md:145`.
6. ~~**App Store entfernen**~~ — **zurückgestellt, nichts anfassen.** Der Operator überlegt es sich noch
   (2026-08-03), also bleiben `features/apps/app-store.component.ts` + `app-deploy.component.ts`, ihre Route
   und der Nav-Eintrag unverändert. Falls es später doch weg soll: vorher prüfen, ob `app-deploy`
   Backend-Endpunkte exklusiv nutzt, die dann verwaisen.

## Was aus ansible-manager übernommen wird

Schon portiert (`bossman-ui/src/app/features/runbooks/blockly/`): `blocks.js`, `ansibleGenerator.js`,
`playbookImporter.js`, `conditionParser.js`, `toolbox.js`, `ansibleFacts.js`, `varInsertion.js`,
`sidecarPath.js`, `blocklyUtil.js`, `moduleCatalog.generated.json`.

**Nicht portiert, hier fällig:** `VariablesPanel.js` (Schritt 1) und `TemplatesPanel.js` (248 Z., optional).
Die vier React-Shells (`PlaybookBuilder.js`, `BlocklyWorkspace.js`, beide Panels) sind React — „1:1
kopieren" gilt für die **Logik**-Module (framework-frei, mit Jest-Tests: ~2400 Z. Logik + ~2000 Z. Tests);
die Shells brauchen Angular-Entsprechungen. `BlocklyWorkspace` existiert in yolo-man bereits als
`blockly-workspace.component.ts`.

## Verifikation

1. Rolle mit `parameters:` öffnen → Variablen-Panel zeigt sie; eine per Klick in ein Argument einfügen und in
   ein `when:`; speichern; `POST /runbooks/lint` round-trip ändert das Dokument nicht.
2. Eine Fact aus dem Panel in ein `when:` ziehen und **gegen einen echten Host** dry-runnen — sie muss
   auflösen (das ist der Test, den die falsche `ansible_facts['…']`-Liste heute nicht besteht).
3. Param-Form: eine Rolle mit vielen defaulteten Optionen zeigt nur die Pflichtfelder; *Advanced* öffnet den
   Rest; gespeichertes Dokument enthält keine unnötigen Default-Werte (bereits gebaut, Regression prüfen).
4. Suche: „Search Within = Variable Name" findet einen Step über seinen `register`-Namen; „Filter By = Has
   Conditions" zeigt nur Steps mit `when:`.
5. App Store: Route weg, kein toter Nav-Eintrag, `npx ng build` grün, keine verwaisten Endpunkte.
