# Rollen-Deployments (Desired State)

Rollen und Features werden nicht mehr als einmaliger Runbook-Aufruf behandelt. Ein Deployment ist ein
dauerhaftes Objekt mit Zielbereich, festgeschriebener Artefaktversion, Parametern, Freigabe-/Pilotstatus und
einem Compliance-Ergebnis je Host. Der Ablauf orientiert sich an Configuration Manager:

1. **Artefakt wählen** — Katalogeinträge und selbst geschriebene Rollen werden als versionierte
   `OrchestrationPlan`s veröffentlicht.
2. **Ziel festlegen** — Host, Hostgruppe, OU (mit Unter-OUs), Site (über Subnetze) oder global — in UI und
   API dieselben fünf Bereiche.
3. **Preview** — sperrt Zielmitgliedschaft, Artefaktversion, Parameter und Pilotwahl in einem Hash. Zusätzlich
   wird pro Artefakt geprüft, auf welchen Betriebssystemfamilien es anwendbar ist; Hosts, auf denen es nur mit
   den Paketnamen einer anderen Familie anwendbar ist (`substituted`), werden mit Grund getrennt genannt. Jede
   Feldänderung verwirft die Preview; ändert sich die Mitgliedschaft zwischen Preview und Create, antwortet die
   API 409 „preview again".
4. **Freigabe/Pilot** — globale oder große Deployments benötigen eine Vier-Augen-Freigabe; jedes andere kann
   sie mit „Require approval by a second administrator" anfordern. Der Ersteller sieht „Approve" ausgegraut mit
   Grund. Ab mehr als zehn Hosts wird ein Pilot vorgeschlagen; erst wenn der Pilot 30 s compliant ist, wird die
   Hauptgruppe bearbeitet — die Zielzeile nennt den Wartegrund (`waiting_for`).
5. **Apply + Detection** — das gepinnte Runbook wird angewandt und danach im Check-Modus verifiziert.
   `service: restarted/reloaded` wird für die Erkennung zu `started` normalisiert, damit ein notwendiger
   Installations-Restart nicht dauerhaft als Drift erscheint.
6. **Compliance** — `compliant`, `noncompliant`, `not_applicable`, `blocked`, `error` und Übergangszustände
   werden je Rolle/Feature und Host gespeichert, jeweils mit Grund (`last_error`): Drift nennt die Schritte
   („drift detected in: Render configuration"), ein Host mit geschlossenem Write-Gate ist `blocked`. Drift wird
   nur gemeldet; Korrektur benötigt eine zusätzliche Bestätigung.
7. **Entfernen** — Standard ist **Stop managing** und lässt Software/Config unverändert. **Uninstall** ist eine
   separate Bestätigung und steht für kataloggestützte Linux-Pakete und Windows-Features zur Verfügung; bei einer
   selbst geschriebenen Rolle ist der Knopf ausgegraut (`uninstall_blocked` nennt den Grund, die API antwortet 422).

## Integration von Rollen und Runbooks

- Der Package-Katalog veröffentlicht beim Start und beim periodischen Reseed ein Systemartefakt
  `catalog__<name>`. Vorhandene `install-<name>`-Runbooks liefern die Schritte.
- Katalogeinträge ohne Config-Wizard bekommen einen deklarativen Fallback für Linux `package` bzw. Windows
  `windows_feature`; damit sind auch paket-only und native Windows-Rollen deploybar.
- Das Speichern einer selbst geschriebenen `role:` veröffentlicht automatisch eine neue unveränderliche
  Artefaktversion. Bestehende Deployments bleiben auf ihrer bisherigen Version gepinnt.
- Erst ein erfolgreich verifiziertes Ziel erzeugt einen aktiven, versionsgepinnten Host-Link. Dadurch gelangen
  Rolle, Parameter und deklariertes Monitoring in den kompilierten Desired State.
- Ein normales Runbook bleibt eine einmalige Prozedur. Nur `role:`-Dokumente und Katalogrollen gehören in
  diesen Compliance-Lebenszyklus.

## Versionen

Jede gespeicherte Änderung einer `role:` ist eine neue unveränderliche Version (das Speichern meldet
„role artifact vN"; unveränderter Text erzeugt keine). Roles & Features → *Version history* listet die Versionen
und vergleicht zwei davon im selben Diff-View wie die Plan-Bibliothek (`shared/version-diff`).

## Rollenbindungen und Freigabe

Eine Rollenbindung am Host (Management → Role bindings → Bind) ist bei ausgeschaltetem YOLO `pending_approval`.
Freigegeben wird an genau einer Stelle: **Deploy → Change proposals**, Abschnitt „Role bindings awaiting approval".
Nur ein Administrator gibt frei, nie der Antragsteller (`created_by`); ablehnen dürfen Administratoren und der
Antragsteller selbst (Rückzug). Mit YOLO an ist eine Bindung sofort aktiv.

## Bedienung

- **Deploy → Roles & Features**: zentrale Erstellung, Preview, Freigabe, Pilot und Compliance.
- **Host → Management → Roles & Features**: vertrauter „Add roles and features“-Assistent für einen Host;
  dessen Install-Schritt erzeugt intern dasselbe Deployment.
- In der Hostansicht kann Drift nach Bestätigung korrigiert und pro Rolle zwischen „Stop managing“ und
  „Uninstall“ gewählt werden.

## Betrieb

Vor dem Start muss die Migration `c7e52a91d4b8` angewandt werden. Der Worker läuft standardmäßig alle 60
Sekunden und kann über `BOSSMAN_ROLE_DEPLOYMENT_ENABLED` bzw.
`BOSSMAN_ROLE_DEPLOYMENT_INTERVAL_SECONDS` gesteuert werden. Gleichzeitiger Worker- und UI-Start wird durch
eine Deployment-Sperre serialisiert.

Zeitpläne sind bewusst nicht Teil der ersten Ausbaustufe; Scheduler und Runbook-Rollouts bleiben für
zeitgebundene Einmalaktionen bestehen.
