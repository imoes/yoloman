# Rollen & Features: Definition + Katalog-Ausbau (~100 Pakete)

> Eigener Plan (PXE-Projekt bleibt in `docs/pxe-baremetal-imaging.md`).

## Kontext

Der Rollen-&-Features-Katalog (`configs/package_catalog.json`) hat heute nur **38** kuratierte Einträge
(24 `role`, 14 `config`). Der Operator will (a) klar definieren, was eine **Rolle** und was ein **Feature**
ist, und (b) deutlich mehr Pakete anbieten. Kernidee des Operators:

- Ein **Feature** (z. B. SSH-Server) tut beim Hinzufügen **nichts** außer: Paket installieren, und danach
  ist dessen **Config editierbar**. Nichts zu erfinden — die Config eines installierten Pakets wird ohnehin
  angezeigt (wir haben bereits **3222** `config_templates`, u. a. `sshd_config`, `openssh-server`).
- Eine **Rolle** ist mehr: „was ein *Typ Host* sein soll" — Installation **+** Dienst **+** Monitoring-Check
  **+** Notification-Routen (der OrchestrationPlan-/Role-Binding-Pfad, der schon existiert).

Der Katalog wird **nicht** über alle 9000 Pakete erweitert (zu viel), sondern um eine **Vorauswahl von ~100
gängigen Server-Paketen** — abgeleitet aus der kategoriesortierten Installer-Auswahl (Debian `tasksel`,
RedHat/Fedora `comps`-Gruppen) + Popularität (`popcon`), geschnitten mit den bereits vorhandenen
`config_templates`. Die Einstufung role/feature/config macht `qwen35b` als kleiner Schritt; die Config ist
für fast alle schon da.

## Was schon da ist (nicht neu bauen)

- **`configs/package_catalog.json`** (`api/package_catalog.py`): `{name: {label, category, icon, description,
  template, kind, validate_cmd?, families:{debian,redhat:{packages,service,config_path}}}}`. `kind` ist
  heute `'role' | 'config'`.
- **`CatalogPackage.kind`** (`core/services/package-catalog.service.ts`) — `kind` wird an genau **3** Stellen
  konsumiert: `roles-features.component.ts:100,117` (Rollen vs. Config-Dateien trennen) und
  `add-roles-wizard.component.ts:340` (`kind === 'config'` überspringt Nicht-Installierbares).
- **3222 `config_templates`** = Paket→Config-Datei-Universum. Für ein Feature ist damit die Config schon
  abgedeckt; ein Feature braucht nur einen Katalogeintrag (+ optional Service).
- **OpenRouter-Client mit Guard** (`scripts/retranslate_checks.py`): `OPENROUTER_API_KEY` aus der Env,
  `_openrouter_remaining()` (Credit-Guard, Abbruch unter `_OPENROUTER_MIN_CREDITS`), Resume-Muster. Modell
  dort ist `poolside/laguna-s-2.1` (ein *Coding*-Modell) — für Klassifikation/Metadaten nehmen wir ein
  starkes **General**-Modell (s. offene Frage).
- **Wizard** (`add-roles-wizard.component.ts`) installiert + konfiguriert + (optional) Monitoring-Check.

## Teil 1 — Definition Rolle / Feature / Config (deterministisch, kostenlos)

**Grundlage: Microsofts Windows-Server-Definition** (die UI ist „Add Roles and Features" nachgebaut):
- **Role** = *primäre Funktion* des Servers — was er fürs Netzwerk **ist** und **anderen Hosts bereitstellt**
  (DNS, Web, Datei, DB, DHCP, Mail).
- **Feature** = *auxiliäre/unterstützende* Funktion, **nicht** die Primärfunktion; ergänzt eine Rolle oder
  den Server selbst (MS-Beispiel: Failover Clustering ergänzt File Services).
- (Role Services = optionale Unterkomponenten einer Rolle — bei uns vorerst nicht modelliert.)

Übersetzt auf yolo-man/Linux — `kind` bekommt einen dritten Wert `'feature'`:

| kind | Was es ist | Beim Hinzufügen | Monitoring/Notif. | Config | Beispiele |
|---|---|---|---|---|---|
| `role` | Primärdienst für **andere Hosts** | install **+ im Wizard konfigurieren + Dienst enable/start + Monitoring-Check + Notification-Routen** | **ja** | ja | nginx, apache, postgresql, bind9, samba, dhcpd, postfix |
| `feature` | unterstützend / Zugang zum Host selbst / Tool | install **+ im Wizard konfigurieren + Dienst enable/start** | **nein** | ja | openssh-server, fail2ban, chrony, cron, pacemaker, restic |
| `config` | Basissystem-Datei, **kein** Install | nur Datei editieren (gpedit) | nein | ja | sysctl.conf, NetworkManager.conf, limits.conf |

**Korrigiert (Operator):** ein **Feature wird installiert, im Wizard konfiguriert, enabled und gestartet** —
genau wie eine Rolle. Der **einzige** Unterschied ist die **Monitoring-/Notification-Schicht**: eine Rolle
ist der überwachte Primärzweck des Hosts, ein Feature nicht. (Deckt sich mit MS: primär vs. unterstützend.)

Merksatz fürs Mining: **„Stellt es anderen Hosts einen Dienst bereit und würde man es als Zweck des Hosts
überwachen?" → Rolle. Sonst installierbar → Feature. Kein Paket, nur Datei → config.** Grenzfälle bleiben
Vorschläge; der Operator kann jeden Eintrag umklassifizieren.

- **Doku:** `docs/roles-and-features.md` mit dieser MS-fundierten Tabelle + SSH-Beispiel + Quelle
  (learn.microsoft.com/.../server-manager/add-remove-roles-features).
- **Code:** `'feature'` in die `kind`-Union (`package-catalog.service.ts`); die 3 Konsumenten so anpassen,
  dass ein Feature **installierbar** ist (wie `role`), im Wizard aber der Monitoring-Check-/Role-Schritt
  **übersprungen** wird (Feature = install + config, keine Orchestrierung). `roles-features.component`
  gruppiert künftig Roles / Features / (Config bleibt im Configuration-Tab).

## Teil 2 — Klassifikation IN den qualify-Lauf integrieren (keine doppelte Arbeit)

**Vorauswahl statt 9000 (dein Cut): ~100 kuratierte Pakete.** Nicht alle qualifizierten Pakete werden
eingestuft, sondern nur die gängigen Server-Pakete — genau die, die die Installer schon **kategoriesortiert**
anbieten:
- **Debian `tasksel`** (Web-/Mail-/DNS-/Print-/File-/SSH-/DB-Server …) + die Paketlisten der Tasks.
- **RedHat/Fedora `comps`-Gruppen** (`@web-server`, `@mail-server`, `@dns-server`, `@file-server` …).
- Ranking/Ergänzung via **popcon** (popcon.debian.org).
- **∩ vorhandene `config_templates`** — bereits geprüft: **38 von ~40** bekannten Server-Daemons haben schon
  ein Template (nginx, apache2, postgresql, mariadb, bind9, dnsmasq, samba, postfix, dovecot, redis, haproxy,
  chrony, fail2ban, openssh-server, docker, cups, squid, openvpn, wireguard, slapd, …). **Die Config ist also
  fast komplett da — es fehlt nur die Einstufung.**

Die Kandidatenliste (~100) wird als **kuratierter Seed** committet (reproduzierbar/reviewbar), abgeleitet aus
tasksel/comps/popcon; wo verfügbar zieht das Skript sie live über den Corp-Proxy, sonst aus dem Seed. Die
Installer-**Kategorie** wird direkt als Katalog-`category` übernommen (der Installer sortiert schon).

Eingestuft werden **nur diese ~100** — kein 9000-Lauf, kein Neuschreiben von Templates. Ein separater
Manpages-/Gemini-Lauf würde die vorhandene `.deb`-Erdung doppeln; deshalb liest der Classify-Schritt aus den
schon erzeugten Artefakten.

**Kein Neuschreiben fertiger Arbeit.** PIPELINE_VERSION bleibt `v6-enriched` — die vorhandenen Templates/
Codecs werden anhand ihrer Version **nicht** angefasst. Der Classify-Schritt läuft nur für die ~100
Kandidaten und schreibt **nur** den Katalog + eine eigene Marke `classify_done[name]` (eigene
`CLASSIFY_VERSION`), damit ein erneuter Lauf die Einstufung nicht wiederholt.

1. **Classify** — für jedes der ~100 Kandidaten-Pakete. Liest **aus den vorhandenen Artefakten**, zieht das
   `.deb` NICHT neu:
   - `config_path` ← aus `config_codecs.json` bzw. dem vorhandenen config_template (schon extrahiert).
   - `debian_packages` ← Paketname; `template` ← das vorhandene config_template-Verzeichnis.
   - `category` ← aus der tasksel/comps-Gruppe (Installer-Kategorie), sonst vom Modell.
   - Manpage-Kurzbeschreibung (lokal) → Kontext fürs Modell.
   - `service` ← günstig aus Paketname/Manpage (nur für den Monitoring-Hinweis einer Rolle).
2. **LLM nur für Klassifikation + Prosa** (dasselbe `qwen35b`, das qualify schon nutzt — **kein zweiter
   Lauf, keine Extra-Kosten**): `{classify: role|feature|config|skip, label, category, icon, description}`.
   Alles Strukturelle kommt deterministisch aus Schritt 1. **Kein `max_tokens`** (globale Regel); bei
   abgeschnittener Ausgabe Thinking abschalten statt cappen.

   **Entwurf Klassifikations-Prompt** (zur Bestätigung):
   > Classify one Linux package for a "Roles and Features" catalog modeled on Windows Server Server Manager
   > (Microsoft's distinction — role = the server's PRIMARY function provided to OTHER hosts, monitored as
   > the host's purpose; feature = auxiliary/supporting, or access to the host itself, or a tool/agent —
   > installed and configured and run, but NOT the host's monitored purpose).
   > Given: package name, its section-5/8 man-page summary, and its real shipped `/etc` config path.
   > Return STRICT JSON: `{"classify":"role|feature|config|skip","reason","label","category":"<web|database|
   > network|storage|security|system|time|virtualization|mail|directory|monitoring|backup|services>",
   > "icon":"<material-icons>","description":"<one sentence>"}`.
   > role examples: nginx, apache2, postgresql, mariadb, bind9, dnsmasq, isc-dhcp-server, samba, postfix.
   > feature examples: openssh-server, fail2ban, chrony, cron, pacemaker, restic, ufw.
   > skip: a library, a section-3 function, or a one-shot CLI with no daemon and no config. Unsure between
   > role and feature → prefer feature.
3. **Merge** in `package_catalog.json` **additiv** (kuratierte 38 Einträge nie überschreiben, Dedup nach
   Name). **PIPELINE_VERSION NICHT bumpen** — nur `classify_done`/`CLASSIFY_VERSION` steuert den neuen
   Schritt. Erst `--dry-run`-Report (X role / Y feature / Z config / skip), dann scharf.

> Alternative, falls höhere Klassifikationsqualität gewünscht: den Classify-Schritt gegen
> `google/gemini-2.5-flash` (OpenRouter, Guard aus `retranslate_checks.py`) statt qwen35b — das ist der
> einzige Punkt, an dem ein Extra-Modell Sinn ergäbe. Standard = qwen35b in-pipeline (keine Doppelarbeit).

## Kritische Dateien

| Datei | Änderung |
|---|---|
| `docs/roles-and-features.md` | **neu** — Definition der 3 kinds + SSH-Beispiel |
| `bossman-ui/.../core/services/package-catalog.service.ts` | `'feature'` in die `kind`-Union |
| `bossman-ui/.../features/hosts/management/roles/roles-features.component.ts` | Roles/Features gruppieren; Feature installierbar |
| `bossman-ui/.../features/hosts/management/roles/add-roles-wizard.component.ts` | Feature = install + config, Monitoring-Schritt überspringen |
| `configs/roles_features_seed.json` (o. ä.) | **neu** — die kuratierte ~100er-Kandidatenliste (tasksel/comps/popcon ∩ config_templates), reviewbar committet |
| `bossman/scripts/classify_roles_features.py` (o. ä.) | **neu/klein** — Classify der ~100 (qwen35b), liest vorhandene Artefakte, Merge additiv, `classify_done`-Marke |
| `configs/package_catalog.json` | additiv erweitert (~100 neue role/feature-Einträge) |

Wiederverwenden: `retranslate_checks.py` (OpenRouter-Client, Credit-Guard, Resume), die 3222
`config_templates` (Config + config_path), `package_catalog.py` (Katalog-Vertrag), das Wizard-Gerüst.

## Verifikation

1. Teil 1: `npx ng build` grün; im Browser zeigt Roles & Features die drei Gruppen; ein **Feature**
   hinzufügen installiert nur das Paket und dessen Config ist im Configuration-Tab editierbar; eine
   **Rolle** bekommt weiter einen Monitoring-Check.
2. Teil 2 dry-run: der Report zeigt plausible Zahlen (z. B. „X features, Y roles, Z skipped") und die
   Kandidatenliste ist nachvollziehbar; Stichprobe von ~10 Einträgen von Hand geprüft (Paketname, service,
   config_path stimmen).
3. Teil 2 apply: `package_catalog.json` wächst, kuratierte Einträge unverändert, jeder neue Eintrag
   valide (`families`, `kind`); Katalog lädt in der UI.
4. **Kein Neuschreiben**: nach einem Neustart des Batches bleibt die mtime/der Inhalt der vorhandenen
   `config_templates/*/template.j2` + `config_codecs.json` **unverändert** (nur `classify_done` + der Katalog
   ändern sich). Das ist der Beweis, dass die erledigte Arbeit nicht gedoppelt wird.

## Entscheidungen / offene Fragen

- **Definition** (bestätigt): Feature = install + konfigurieren + enable + start; Rolle = dasselbe +
  Monitoring + Notifications; config = kein Install. Einziger Unterschied Rolle↔Feature = die
  Monitoring-/Notification-Schicht.
- **Keine Doppelarbeit** (bestätigter Einwand): Klassifikation als **Schritt in `qualify_packages.py`**,
  nicht als separater Manpages-/Gemini-Lauf — die `.deb`-Erdung ist schon da.
- **Modell** (bestätigt): `qwen35b` — für ~100 Pakete günstig; Gemini Fallback bei zu grober Qualität.
- **Umfang** (bestätigt): **~100** kuratierte Server-Pakete aus tasksel/comps/popcon ∩ config_templates —
  nicht die 9000. Kein Batch-Restart über alles.
