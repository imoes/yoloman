# Event handling — ein Handler, zwei Körper, zwei Herkünfte

> Nutzervorgabe (wörtlich): „Das soll als Runbook oder Skript (Bash, Python, etc.) ausgeführt
> werden können. Mit Parameter Übergabe um die Skripts variabel zu halten. Die Event handler
> werden entweder von bossman verwaltet und verteilt oder sie liegen lokal in einem Bestimmten
> Verzeichnis wo der agent sie finden kann. Natürlich dann ohne Parameter. Parameter können nur
> in Bossman konfiguriert werden."
> Und auf die Rückfrage, ob ein lokal liegender Handler auch lokal ausgelöst werden könne:
> „Das ist wohl unlogisch oder? Es kann nur ein Bossman verwalteter Event handler getriggert
> werden." → **Bossman ist immer der Auslöser.** Nur der *Körper* liegt woanders.

## 1. Was schon existiert (und deshalb nicht neu gebaut wird)

Diese Prüfung stand am Anfang, weil dieses Projekt sonst genau den Fehler wiederholt, den das
Logik-Audit die ganze Zeit findet: ein zweiter Weg zum selben Ergebnis.

| Baustein | Wo | Kann schon |
|---|---|---|
| **Auslöser** | `services/remediation.py` | Ein Check geht in einen harten Problemzustand → Policy greift |
| **Bindung** | `RemediationPolicy` | `match_service_name` + Scope (global/OU/Gruppe/Host) + `conditions` |
| **Ausführung Runbook** | `services/runbook_exec.execute_runbook` | Runbook **mit Parametern** auf dem Host |
| **Leitplanken** | `RemediationPolicy` | `max_per_hour`, `autonomy` (propose/auto_verify), `allow_prod`, `max_blast_radius`, Kill-Switch |
| **Nachkontrolle** | Phase 1/2 | `verify` + `verify_after_s`, Eskalation, `rollback_runbook` |
| **Audit** | `RemediationRun` | jeder Lauf mit Ergebnis, apply/dismiss |
| **Skript ausführen** | Agent-Modul `script` / `command` | Ein auf dem Host liegendes Skript ausführen (rc/stdout/stderr) |
| **Skript ausbringen** | Agent-Modul `copy` | Inhalt + `dest` + `mode` — genau der Weg, den die Disk-Verwaltung für die LUKS-Passphrase nutzt |
| **Lokale Handler finden** | Agent-Modul `find` | Ein Verzeichnis auflisten |

**Folge:** Event-Handling braucht **keinen** neuen Auslöser, keine neue Leitplanke und kein neues
Audit. Es braucht genau das, was fehlt: einen **Handler als eigenes, benennbares Objekt**, dessen
Körper auch ein Skript sein darf.

> **Korrektur zu diesem Absatz:** hier stand zuerst zusätzlich „und keine Zeile Agent-Code". Das
> war falsch — `command` hatte keinen `env`-Parameter, und Parameter als Umgebungsvariablen sind
> der Kern des Entwurfs. Details unter „Korrektur am eigenen Entwurf" weiter unten. Der Satz
> bleibt hier korrigiert stehen statt gelöscht, weil die Tabelle darüber genau die Prüfung ist,
> die den Irrtum hätte verhindern sollen: ich hatte `copy`/`script`/`find` nachgesehen, `env`
> aber nicht.

## 2. Das Objekt

`EventHandler` — die wiederverwendbare *Aktion*. Bisher war die Aktion ein Feld an der Policy
(`runbook_name` + `params`), also nicht wiederverwendbar und nicht auf Skripte erweiterbar.

```
EventHandler
  name            eindeutig, wird in der Policy referenziert
  description
  body            runbook | script          ← WAS ausgeführt wird
  location        managed | local           ← WOHER der Körper kommt (nur für script)
  runbook_name    body=runbook
  interpreter     body=script: bash | sh | python3 | …
  source          body=script, location=managed: der Skripttext (in Bossman gepflegt)
  local_name      body=script, location=local: Dateiname in /etc/agentic-mcp/event-handlers/
  parameters      [ {name, type, default, description, required} ]  ← NUR in Bossman
  timeout_s
```

### Die vier erlaubten Kombinationen — und die eine verbotene

| body | location | Parameter | Ausführung |
|---|---|---|---|
| `runbook` | — | ✅ | `execute_runbook` wie heute |
| `script` | `managed` | ✅ | `copy` (Text → `/etc/agentic-mcp/event-handlers/<name>`, mode 0700) **dann** `command` |
| `script` | `local` | **❌** | `command` auf `/etc/agentic-mcp/event-handlers/<local_name>` |
| `runbook` | `local` | — | **existiert nicht** |

Die letzte Zeile ist kein Versehen: ein Runbook ist ein Dokument in Bossmans Datenbank, es
*kann* nicht lokal liegen. Der Typ muss diese Kombination daher unmöglich machen
(Constraint), nicht das UI abfangen — Regel 2 des Logik-Audits.

**Warum lokal ohne Parameter** (die Nutzervorgabe, mit ihrem Grund): Bossman kennt den Inhalt
eines lokal abgelegten Skripts nicht. Es könnte also nicht sagen, welche Parameter es annimmt,
welche Typen sie haben oder ob sie erforderlich sind — jede angebotene Parameterliste wäre
geraten. Ein Formular, das Werte für unbekannte Parameter erfragt, verspricht eine Wirkung, die
niemand prüfen kann. Deshalb: lokal = Aufruf ohne Argumente, und das Formular zeigt **warum**,
statt das Feld nur auszugrauen.

## 3. Wie Parameter ankommen

Ein Skript bekommt sie als **Umgebungsvariablen**, nicht als Positionsargumente:
`BOSSMAN_<PARAM>` in Großbuchstaben. Begründung: Positionsargumente sind reihenfolgeabhängig
und stillschweigend falsch, wenn ein Parameter hinzukommt; benannte Variablen brechen nicht
beim Erweitern. Dazu kommt immer der **Ereigniskontext**, damit ein Handler weiß, warum er
läuft:

```
BOSSMAN_EVENT_HOST        Hostname
BOSSMAN_EVENT_SERVICE     Service-/Checkname, der ausgelöst hat
BOSSMAN_EVENT_STATE       WARN | CRIT | UNKNOWN
BOSSMAN_EVENT_VALUE       Messwert (leer, wenn keiner)
BOSSMAN_EVENT_HANDLER     Name des Handlers (für Logzeilen)
BOSSMAN_EVENT_RUN_ID      die RemediationRun-Zeile — verbindet Hostlog und Audit
```

Auch der lokale Fall bekommt diesen Kontext: er ist **kein Parameter**, sondern die Tatsache,
die den Lauf ausgelöst hat — Bossman kennt sie immer, unabhängig vom Skriptinhalt.

## 4. Wie es an den Auslöser kommt

`RemediationPolicy` bekommt **ein** Feld: `event_handler_id`. Entweder-oder zum bestehenden
`runbook_name`, per Constraint erzwungen; `runbook_name` bleibt gültig, damit bestehende
Policies unverändert laufen. Alles andere — Auslöser, Scope, Ratenbegrenzung, Autonomie,
Verifikation, Rollback, Audit — bleibt exakt wie es ist.

Damit geht `/remediation-*` **auf** statt daneben zu liegen: die 7 Endpunkte werden die
Oberfläche des Event-Handlings, nicht ein zweites Subsystem.

Benennung (Regel 1): das Objekt heißt im Code, in der API und im UI **Event handler**; die
Policy, die ihn an einen Auslöser bindet, heißt **Event rule**, nicht länger „Remediation
policy" — „Remediation" beschreibt nur einen Zweck von mehreren (benachrichtigen, aufräumen,
eskalieren sind keine Reparatur).

## 5. Was sichtbar sein muss (die Prüffragen, vorab beantwortet)

- **Zureichender Grund:** Jeder Lauf nennt Handler, Auslöser, Parameterwerte und rc/stdout —
  `RemediationRun` trägt das schon, das UI muss es zeigen.
- **Falsifizierbarkeit:** Bei `location=local` muss ablesbar sein, ob die Datei auf dem Host
  **existiert**. Ohne diese Anzeige ist ein lokaler Handler eine Behauptung: er läuft erst beim
  Ereignis, und dann fehlt er womöglich. Deshalb: Bossman listet per `find` das Verzeichnis der
  betroffenen Hosts und zeigt „vorhanden auf N von M Hosts".
- **Ausgeschlossenes Drittes:** Ein Handler, dessen lokale Datei fehlt, ist ein **benannter**
  Zustand („missing on host"), keine leere Zeile.
- **Widerspruchsfreiheit:** Ein `managed`-Skript wird bei jedem Lauf ausgebracht, bevor es
  läuft. Sonst könnte auf dem Host eine ältere Fassung liegen als die, die Bossman anzeigt —
  zwei Wahrheiten für denselben Körper.

## 6. Reihenfolge der Umsetzung

1. Modell + Migration (`event_handlers`, `remediation_policies.event_handler_id`) samt
   Constraints für die verbotenen Kombinationen.
2. Service: `services/event_handlers.py` — Körper auflösen, Parameter in Umgebung übersetzen,
   `managed` ausbringen, ausführen; `services/remediation.py` ruft es statt direkt
   `execute_runbook`.
3. API: `/event-handlers` CRUD + `/event-handlers/{id}/availability` (die `find`-Prüfung).
4. UI: Handler-Editor + die Anzeige „vorhanden auf N von M Hosts"; die Event-Regeln daneben.
5. Erst danach umbenennen (Remediation policy → Event rule), als eigener Schritt, damit ein
   Fehler in der Umbenennung nicht mit einem Fehler in der Funktion vermischt wird.

---

## Umsetzungsstand

### Schritt 1 — Modell + Migration (erledigt, Commit)

`EventHandler` + `remediation_policies.event_handler_id`, Migration `f7c2a8e14b93`. Die
verbotenen Kombinationen sind **CheckConstraints**, live gegen die DB geprüft: `runbook+local`,
lokales Skript **mit** Parametern, `managed` ohne `source`, Regel mit beiden bzw. keiner Aktion
— alle vier abgewiesen; die drei erlaubten Formen akzeptiert. `ON DELETE RESTRICT`: ein Handler,
den eine Regel benutzt, lässt sich nicht löschen (statt `SET NULL`, das eine Regel hinterließe,
die feuert und nichts tut, oder `CASCADE`, das fremde Regeln mitnimmt).

### Korrektur am eigenen Entwurf: es BRAUCHTE eine Agent-Änderung

Der Entwurf behauptete „keine Zeile Agent-Code". Beim Nachsehen — nicht beim Annehmen — hatte
das `command`-Modul überhaupt keinen `env`-Parameter, und kein anderes Modul auch. Parameter als
Umgebungsvariablen sind aber der Kern des Entwurfs, also war die Zusage falsch.

`env` ist jetzt Teil von `command` (und damit von `script`, das es umhüllt), mit zwei getesteten
Eigenschaften: die Variablen werden zur **geerbten** Umgebung **hinzugefügt** (ein Skript ohne
PATH/HOME scheitert aus einem Grund, den der Aufruf nicht beschreibt), und ein Nicht-String-Wert
wird **abgewiesen** statt stillschweigend formatiert. Warum Umgebung und nicht Kommandozeile:
`VAR=wert /pfad/skript` stellt jeden Wert in die Prozessliste und in die Shell-Historie.

### Schritt 2 — Ausführungsschicht (erledigt, Commit)

`services/event_handlers.py`, 16 Tests ohne DB und ohne Host:

| Eigenschaft | Warum sie so ist |
|---|---|
| `managed` wird **vor jedem** Lauf ausgebracht (`copy`, mode 0700), dann `command` | Einmal kopieren ⇒ der Host hielte womöglich eine ältere Fassung als die, die Bossman zeigt: zwei Wahrheiten für einen Körper |
| Jeder **deklarierte** Parameter kommt an (Wert → Default → leer) | Für ein Shell-Skript sind „Variable fehlt" und „Variable leer" verschiedene Fehler; nur einer davon ist die Absicht |
| **Nicht deklarierte** Werte werden verworfen | Die Deklaration ist der Vertrag des Handlers; heimlich mehr durchzureichen macht ihn unlesbar |
| `local` bekommt **keine** Parameter, aber **immer** den Kontext | Der Kontext ist kein Parameter, sondern die auslösende Tatsache — die kennt Bossman unabhängig vom Skriptinhalt |
| Fehlender Pflichtparameter ⇒ Abbruch **vor** jedem Hostzugriff, mit Namen | Nichts wird kopiert oder gestartet, wenn der Aufruf unvollständig ist |
| `rc != 0` ⇒ protokollierter Fehlschlag mit Code + erster Ausgabezeile | Ein Skript, das ungleich 0 endet, ist ein Ergebnis, kein Absturz — und die Audit-Zeile soll das **warum** enthalten |
| `local_name` wird auf den **Basisnamen** reduziert | `../../etc/shadow` → `…/event-handlers/shadow`: ein Event-Handler ist kein Weg, beliebige Dateien auszuführen |

**Beim Bauen gefunden:** `find` liefert seine Treffer als **Liste** von `{path,isdir,size}`, nicht
als Objekt. Der Helfer aus `disk_ops`, den ich zuerst kopiert hatte, presst alles in ein dict —
damit hätte `local_availability` **jeden** lokalen Handler als fehlend gemeldet. Gegen
`internal/modules/find.go` geprüft und korrigiert, mit einem Test auf die Listenform.

`services/remediation.py` ruft `run_handler`, wenn die Regel auf einen Handler zeigt; sonst
läuft der bisherige Runbook-Pfad unverändert.

### Schritt 3 — API (erledigt, Commit)

`api/event_handlers.py`: CRUD unter `/api/v1/event-handlers` plus
`/event-handlers/{id}/availability`. Live geprüft, dass **jede** Verweigerung ihren Grund nennt
statt nur einen Statuscode:

| Versuch | Antwort |
|---|---|
| managed Skript, lokales Skript | 201, mit `script_path` |
| Runbook `local` | 422 „a runbook is a document in Bossman's database, so there is nothing on the host to point at" |
| lokal **mit** Parametern | 422 mit der vollen Begründung (Bossman kennt den Skriptinhalt nicht) |
| managed ohne `source` | 422 „that text IS the handler" |
| unbekanntes Runbook | 422 „no runbook named …" — jetzt, nicht erst beim Ereignis |
| Name doppelt | 409 |
| `availability` auf einem managed/runbook-Handler | 422 mit dem Grund, warum die Frage dort keinen Sinn hat |

`availability` ist der Beobachtungspunkt für lokale Handler und live belegt: erst **0 von 2**,
nach dem Ablegen der Datei auf einem Host **1 von 2** — je Host benannt (`present` / `missing`),
plus zwei weitere benannte Zustände: `unreachable` (Host ohne Adresse: „nicht da" und „konnte
nicht fragen" sind verschiedene Tatsachen) und `unknown` für eine angefragte ID, die kein Host
ist — sonst hätte eine Frage nach drei Hosts zwei Zeilen ohne Erwähnung der dritten beantwortet.

### Zwei Fehler, die erst der echte Lauf gezeigt hat

```
[Widerspruchsfreiheit] copy legt kein Elternverzeichnis an
  Messung: Der managed-Pfad scheiterte auf einem echten Host mit
           „open /etc/agentic-mcp/event-handlers/cleanup.sh: no such file or directory".
  Problem: Die Unit-Tests benutzen einen Fake-Client und konnten das nicht sehen.
  Fix:     Erst `file state=directory mode=0700`, dann `copy`, dann `command` — im Test als
           Reihenfolge festgehalten.

[Widerspruchsfreiheit] Ein alter Agent IGNORIERT env stillschweigend
  Messung: Auf einem Host mit Agent 0.57.44 lief das Handler-Skript mit rc 0 und gab
           „cleanup ran for  on " aus — der Kontext war leer. Erfolg gemeldet, falsche Arbeit
           getan. Ein stilles falsches Ergebnis ist schlimmer als ein Fehler.
  Fix:     `supports_env` MISST die Fähigkeit vor jedem Skript-Handler (eine Sonde, die einen
           Marker zurück-echot). Nicht über die Version: `list_tools` liefert kein
           Eingabeschema, und eine Version→Feature-Tabelle wäre eine zweite Quelle der
           Wahrheit, die man von Hand nachziehen müsste. Nicht gecacht: eine falsche
           Verneinung kostet nur eine begründete Verweigerung, ein veraltetes „unterstützt"
           brächte genau den stillen Fehllauf zurück.
  Belegt:  Event-Regel auf einen lokalen Handler gebunden und ausgelöst → Status `failed` mit
           „this host's agent cannot pass environment variables … update the agent before using
           a script handler here", und NICHTS wurde auf dem Host ausgeführt.
```

### Schritt 4a — Handler-Oberfläche (erledigt, Commit)

`Library ▸ Event handlers` (`/event-handlers`). Live im Browser durchgespielt:

* Die erlaubten Werte (bodies, locations, interpreters) und das Handler-Verzeichnis kommen aus
  `GET /event-handlers/meta` — in der UI festverdrahtet wären sie eine zweite Quelle der
  Wahrheit, die beim ersten neuen Interpreter auseinanderläuft (dasselbe Muster wie
  `/resource-kinds`).
* Der Ausbringpfad wird beim Tippen mitgeschrieben: „Deployed to
  `/etc/agentic-mcp/event-handlers/clean-logs` (mode 0700) **before every run**".
* Umschalten auf „already on the host" zeigt die **ausformulierte Begründung** vom Server, warum
  es keine Parameter gibt — und **verwirft** die bereits angelegte Parameterzeile, statt sie zu
  verstecken: versteckt gehalten würde das Speichern aus einem unsichtbaren Grund scheitern.
* Das Dateifeld nennt das Verzeichnis im Label statt in einem Hilfetext daneben.
* „Is the file there?" fragt alle Hosts: live **present on 0 of 8**, jede Zeile mit dem exakten
  Pfad und dem Zustand als benanntem Etikett in Fehlerfarbe.
* Ein Warnkasten sagt vorab, dass ein Skript-Handler einen Agenten mit `env` braucht und der Lauf
  sonst **verweigert** wird — statt dass man das später in einer Audit-Zeile findet.
* `Löschen` nennt die Zahl der Regeln, die den Handler benutzen, BEVOR es versucht wird (die API
  verweigert es ohnehin).

Dabei zwei eigene Fehler korrigiert: `Plan` hat kein `plan_type` (die Runbook-Liste kommt aus
`GET /runbooks`, gefiltert auf `kind != 'role'`, weil eine Rolle kein Handler-Körper sein kann),
und ein literales `'<name>'` **im** Template wird von Angular als Tag geparst.

### Schritt 4b (API-Teil) — die Regel kann den Handler überhaupt erst benennen

Beim Bau der Regel-Oberfläche kamen **zwei Lücken** heraus, die vorher niemand sehen konnte:

```
[Ausgeschlossenes Drittes] Kein Endpunkt konnte einen Handler an eine Regel binden
  Beleg:   RemediationPolicyIn kannte `event_handler_id` NICHT — die Spalte existiert, der
           Service liest sie, die Migration hat sie angelegt, aber POST setzte sie nie.
  Problem: Das ganze Event-Handling war per API unerreichbar; nur ein direkter SQL-INSERT
           konnte eine Handler-Regel erzeugen (genau so habe ich in Schritt 3 getestet, was
           den Mangel verdeckt hat).
  Fix:     `event_handler_id` in RemediationPolicyIn/Out, und `_validate_action` nennt bei
           jeder Verweigerung den Grund. Live geprüft:
             beide Aktionen  → 422 „two would be two answers to the question of what runs"
             keine Aktion    → 422 „otherwise it would fire and do nothing"
             Pflichtparameter ohne Wert → 422 mit dem Parameternamen (vor dem Ereignis, nicht
                                          mitten im Lauf auf dem Host)
             unbekannter Handler / deaktivierter Handler / unbekanntes Runbook → je 422

[Widerspruchsfreiheit] „Bearbeiten" trennte die Audit-Historie von ihrer Regel
  Beleg:   Es gab nur POST und DELETE. Eine Regel ändern hieß löschen + neu anlegen, und
           `remediation_runs.policy_id` ist ON DELETE SET NULL.
  Problem: Die vergangenen Läufe blieben stehen, verloren aber die Verbindung zu der Regel,
           die sie verursacht hat — die Historie listet dann Ereignisse, die sie nicht mehr
           erklären kann.
  Fix:     PUT /remediation-policies/{id} ändert in place. Live geprüft: dieselbe id nach dem
           Speichern, geänderte Felder übernommen.
```

### Vor der Regel-Oberfläche gefunden: die Historie konnte nicht sagen, WAS lief

```
[Zureichender Grund] Der Audit-Eintrag einer Handler-Regel war leer
  Beleg:   RemediationRun speicherte nur `runbook_name`, und der ist bei einer Handler-Regel
           per Constraint LEER (services/remediation.py schrieb ihn an beiden Stellen 1:1).
  Problem: Genau für den neuen Fall hätte die Historie Ereignisse gelistet, ohne benennen zu
           können, was ausgeführt wurde. Eine Anzeige darauf zu bauen hätte eine leere Spalte
           hübsch gerahmt.
  Fix:     Migration b3e7d1a48c52 fügt `remediation_runs.action` als „kind:name" hinzu
           („runbook:restart-nginx", „handler:clean-logs"). Die Art gehört zur Tatsache —
           „clean-logs" allein sagt nicht, ob ein Runbook oder ein Skript lief.
  Warum GESPEICHERT und nicht per Join geholt: `policy_id` ist ON DELETE SET NULL. Live
           belegt: Regel gelöscht → `policy_id = None`, `action = 'handler:probe-action'`
           bleibt. Ohne die Spalte hätte das Löschen der Regel die Antwort mitgenommen.
  Bestand: 2 von 3 Altzeilen zurückgefüllt; die dritte bleibt LEER, weil ihr Ursprung
           unbekannt ist — eine erfundene Angabe wäre schlimmer als eine fehlende.
```

### Schritt 4c — Event-Regeln-Oberfläche (erledigt, Commit)

`Monitor ▸ Event rules` (`/event-rules`). Platzierung begründet: der **Handler** wird verfasst
und liegt in Library bei den anderen verfassten Dingen; die **Regel** reagiert — sie wird neben
den Ereignissen gelesen, auf die sie antwortet, und ihre Laufhistorie IST Monitoring-Historie.

Aufbau in der kausalen Reihenfolge: **Wann** (Check, Scope mit passendem Zielfeld) → **Dann**
(die Aktion) → **Leitplanken** → **Läufe**.

```
[Widerspruchsfreiheit] Die Aktion ist EINE Auswahl, nicht zwei Felder
  Grund:   Das Schema erlaubt genau eines von runbook_name / event_handler_id. Zwei Felder
           gleichzeitig anzubieten hieße, zu der Kombination einzuladen, die die Datenbank
           ablehnt. Umschalten LEERT die andere Hälfte sofort (nicht nur ausblenden), und ein
           Handlerwechsel verwirft die Parameterwerte des vorherigen — sie waren für einen
           anderen Vertrag benannt.

[Zureichender Grund] Jede Leitplanke mit einem Satz, was sie tut
  Grund:   Eine Zahl ohne ihre Folge ist eine Einstellung, die niemand beurteilen kann. Live
           sichtbar u.a.: „At most this many runs per host per hour … so a problem that keeps
           re-firing cannot turn into a restart loop"; „Without this, auto_verify refuses on
           hosts marked production".

[Falsifizierbarkeit] Der Lauf ist der Beobachtungspunkt
  Live belegt: Regel per Formular angelegt → ausgelöst → die Tabelle zeigt Zeitpunkt, Host,
           Check, `handler:restart-unit`, Status `failed` und den vollen Grund (der Agent kann
           keine Umgebung übergeben). Ohne diese Spalte wäre „die Regel wirkt" eine Behauptung.
```

Die Sperren nennen ihren Grund, live geprüft: „Pick the event handler to run." → nach der Wahl
„Required parameter(s) without a value: unit." → nach dem Füllen frei. Die Parameterzeile zeigt
Pflichtstatus, Beschreibung UND den Variablennamen `BOSSMAN_UNIT`.

**Eigene Fehler dieser Iteration:** mein Patch für die Route griff NICHT (der Anker hatte sich
durch einen früher eingefügten Kommentar verschoben) — `app.routes.ts` enthielt „event-rules"
null mal, das Bundle aber schon, weil der Nav-Eintrag dieselbe Zeichenkette trägt; die App
leitete still auf `/fleet` um. Erst das Zählen der Treffer hat es aufgedeckt. Und ein `curl` ohne
`-X POST` ließ den Auslöser wie „kein Treffer" aussehen — der Messfehler war meiner.

### Schritt 5 — Umbenennung (erledigt, Commit)

Zuerst gemessen, wer die alten Pfade aufruft, weil davon abhängt, ob ein Wechsel ein Bruch ist:
**genau einer** — mein eigener UI-Client. Kein MCP-Werkzeug, kein Chat-Tool, kein Agent, kein
CLI, und in den Docs nur beschreibend.

| Ebene | Entscheidung | Grund |
|---|---|---|
| API-Pfade | **kanonisch** `/api/v1/event-rules`, `/api/v1/event-runs`, `/api/v1/agents/{id}/trigger-event-rules` | „Remediation" benennt nur einen von mehreren Zwecken — benachrichtigen, aufräumen, eskalieren sind keine Reparatur |
| alte Pfade | bleiben als **Alias**, `deprecated=True` + `include_in_schema=False` | „kein Aufrufer hier" ist nicht „kein Aufrufer irgendwo"; ein `curl`-Skript soll nicht brechen, weil ein Name besser wurde. Es ist dieselbe Funktion, also kein zweiter Weg, der auseinanderlaufen kann |
| UI | ruft nur die neuen Pfade | live belegt: die Netzwerkaufrufe des Screens sind ausschließlich `/api/v1/event-rules` und `/api/v1/event-runs` |
| DB-Tabellen + ORM-Klassen | bleiben `remediation_*` | eine Tabellenumbenennung ist eine Migration und für gespeicherte Daten irreversibel — eine eigene Entscheidung. Code und Tabelle bleiben deckungsgleich, damit es **zwei** Namen mit erklärter Zuordnung gibt statt drei |

Die Zuordnung steht an genau zwei Stellen: im Kopf von `api/remediation.py` und in
`core/models/event-rule.model.ts`. Belegt: alle vier Pfade antworten mit 200, und die Aliase
erscheinen **nicht** im OpenAPI-Schema.

**Offen zur Entscheidung:** ob die Tabellen `remediation_policies` / `remediation_runs` und die
ORM-Klassen mitumbenannt werden sollen. Dafür spricht ein einziger Name; dagegen eine Migration
über gespeicherte Verlaufsdaten, deren Nutzen rein kosmetisch ist.

### Offen

6. Der Agent mit `env` muss ausgerollt werden, sonst verweigert jeder Skript-Handler — mit
   Grund, aber er läuft nicht.
5. Umbenennen *Remediation policy → Event rule* als eigener Commit.
6. Der Agent mit `env` muss auf die Hosts ausgerollt werden, sonst verweigert jeder
   Skript-Handler dort — mit Grund, aber er läuft nicht.
