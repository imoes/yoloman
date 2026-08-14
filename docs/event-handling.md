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

### Offen

4. UI: Handler-Editor (bei `local` die Begründung anzeigen, warum keine Parameter) +
   „vorhanden auf N von M Hosts"; die Event-Regeln daneben.
5. Umbenennen *Remediation policy → Event rule* als eigener Commit.
6. Der Agent mit `env` muss auf die Hosts ausgerollt werden, sonst verweigert jeder
   Skript-Handler dort — mit Grund, aber er läuft nicht.
