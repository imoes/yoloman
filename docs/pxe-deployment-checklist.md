# PXE — Checkliste erstes Deployment

Schritt für Schritt. Nach **jedem** Punkt meldest du kurz zurück (mit der genannten Ausgabe/Beobachtung),
dann prüfe ich das Ergebnis, bevor du weitergehst. Reihenfolge ist nach Abhängigkeit sortiert.

Legende pro Schritt: **Tun** → **Melden** (was du mir schickst) → **Ich prüfe**.

---

## Phase A — Host-Voraussetzungen (auf `hal` bzw. Proxmox-Host)

### A1 — Nested-Virt ✅ (schon erledigt: CPU auf `host` umgestellt)
- **Tun:** Gegenprobe in `hal`: `ls -l /dev/kvm && egrep -c '(vmx|svm)' /proc/cpuinfo`
- **Melden:** die zwei Ausgaben.
- **Ich prüfe:** `/dev/kvm` existiert und der vmx/svm-Count > 0 (Nested wirklich durchgereicht).

### A2 — ens19 ✅ (schon erledigt: 192.0.2.130)
- **Tun:** `ip -4 addr show ens19`
- **Melden:** die Ausgabe.
- **Ich prüfe:** 192.0.2.130 liegt auf ens19, Interface up.

### A3 — Bridge ✅ (erledigt: br-ens19 UP mit 192.0.2.130/24, ens19 als forwarding-Port; Override: PXE_INTERFACE=br-ens19)
<details><summary>nmcli-Befehle (erledigt)</summary>
- **Hinweis:** Die plattenlose Test-VM hängt per `-netdev bridge,br=br-ens19` an einer Bridge mit Zugang
  zum ens19-Segment (192.0.2.0/24). Der Host nutzt **NetworkManager** (Connection `ens19`), daher
  NM-nativ + persistent per `nmcli`. **Achtung:** die IP 192.0.2.130 wandert von ens19 auf die Bridge;
  kurzer Blip **nur** auf dem ens19-Segment (Management liegt auf ens18 → Session bleibt).
- **Tun (als root):**
  ```
  sudo nmcli con add type bridge con-name br-ens19 ifname br-ens19 \
      ipv4.method manual ipv4.addresses 192.0.2.130/24 bridge.stp no
  sudo nmcli con add type ethernet con-name br-ens19-slave ifname ens19 master br-ens19
  sudo nmcli con down ens19            # gibt die IP von der reinen ens19-Connection frei
  sudo nmcli con up br-ens19-slave
  sudo nmcli con up br-ens19
  ```
  Falls ens19 ein Default-Gateway/DNS trug (unwahrscheinlich, da Management auf ens18):
  `ipv4.gateway`/`ipv4.dns` an der br-ens19-Connection ergänzen. Danach in der Override
  `PXE_INTERFACE: br-ens19` setzen (dnsmasq bindet auf die Bridge).
</details>

### A4 — Agent neu bauen ✅ (erledigt: v0.57.42, `agentic-mcpd` + `agent.deb`/`.rpm` frisch, `regex`-Modul im Binary)

---

## Phase B — Konfiguration & Hochfahren

### B1 — `docker-compose.override.yml` (host-lokal, git-ignoriert)
- **Tun:** Override anlegen/ergänzen. `ENROLL_URL`/`PXE_AGENT_ADDRESS`/`BOSSMAN_URL` müssen aus dem
  pxe-Container (Host-Netz) **routbar** sein — nicht `http://bossman:8000`. Beispiel:
  ```yaml
  services:
    bossman:
      environment:
        BOSSMAN_PXE_CONTAINER: agentic-mcp-pxe
        BOSSMAN_IMAGE_BASE_URL: http://192.0.2.130
        # BOSSMAN_NETBOOT_SECRET: hier NICHT nötig — Secret kommt über die WebUI-Karte (Phase D)
    pxe:
      environment:
        BOSSMAN_URL: http://<host-routbare-bossman-adresse>:8123
        ENROLL_URL: http://<host-routbare-bossman-adresse>:8123
        PXE_AGENT_ADDRESS: 192.0.2.130:8051
        BOSSMAN_NETBOOT_SECRET: <bootstrap-secret>   # Bootstrap; WebUI-Secret übernimmt danach
        # PXE_INTERFACE: br-ens19   # nur falls A3-Bridge genutzt
  ```
- **Melden:** den (secret-redigierten) Inhalt deiner Override.
- **Ich prüfe:** Reachability-Adressen plausibel, Container-Name = `agentic-mcp-pxe`, IMAGE_BASE_URL passt
  zum HTTP-Root des Containers.

### B2 — Build + Hochfahren
- **Tun:** `docker compose --profile pxe up -d --build` (der `migrate`-Service fährt `alembic upgrade head`;
  der pxe-Container baut beim ersten Start das PE — das kann ein paar Minuten dauern).
- **Melden:** `docker compose --profile pxe ps` (Status aller Services).
- **Ich prüfe:** `migrate` completed, `bossman`/`db`/`pxe` up, keine Restart-Loops.

### B3 — pxe-Container gesund
- **Tun:** `docker compose logs pxe --tail=60`
- **Melden:** die letzten ~60 Zeilen.
- **Ich prüfe:** dnsmasq(TFTP) + nginx gestartet, `pe.squashfs` gebaut/vorhanden, Agent-Enroll-Zeile
  („agent enrolled as pxe-lab …"), keine „refusing to start"/Fehler.

### B4 — PE + HTTP erreichbar
- **Tun:** `curl -sI http://192.0.2.130/pe.squashfs | head -1` und `curl -sI http://192.0.2.130/agent.deb | head -1`
- **Melden:** die zwei Status-Zeilen.
- **Ich prüfe:** beide `200 OK` (PE + agent.deb werden ausgeliefert).

### B5 — `pxe-lab` erscheint als Host
- **Tun:** in der WebUI unter **Hosts**/**Fleet** nachsehen (oder `curl` gegen die API).
- **Melden:** erscheint `pxe-lab`? Status/enrollment?
- **Ich prüfe:** Agent enrollt, wird gepollt (managed host da → Voraussetzung für Phase C/D).

---

## Phase C — letzte Verdrahtung (mache ICH gegen den laufenden Container)

### C1 — Agent-Config → laufendes dnsmasq + Gating auf `dhcp_enabled`
- **Tun (du):** nur melden, dass B5 grün ist.
- **Ich prüfe/baue:** sobald `pxe-lab` enrollt ist und seine Config-Dateien entdeckt sind, verdrahte ich
  (ein Owner für dnsmasq im systemd-losen Container; Gating „DHCP nur bei pending" auf den Config-Wert
  `dhcp_enabled` aus dem Job-Status). Ich melde dir, wenn C1 deployt/getestet ist.

---

## Phase D — Konfiguration in der WebUI

### D1 — netboot-Secret setzen + aktivieren
- **Tun:** Settings → Karte **„PXE netboot"** → Secret eingeben, **enabled** anhaken, Save.
- **Melden:** „gesetzt + enabled" (Karte zeigt „a secret is set").
- **Ich prüfe:** `GET /system/netboot`-Status (enabled=true, secret_set=true); Gegenprobe, dass ein
  falsches Secret an `/netboot/*` 403 gibt.

### D2 — DHCP-Range als Feature binden
- **Tun:** Config-Template **`dnsmasq.conf`** an `pxe-lab` binden; `dhcp_enabled` an,
  `dhcp_networks = [{interface: ens19, start: 192.0.2.223, end: 192.0.2.224, lease_time: "12h"}]`
  (Gateway/DNS nach Bedarf). Speichern/anwenden.
- **Melden:** Screenshot/Werte der gebundenen Config + „applied".
- **Ich prüfe:** die gerenderte dnsmasq-Config am Host hat die Range korrekt; passt zum Gating aus C1.

---

## Phase E — End-to-End (über QEMU-Test-Ziel, ohne echte Hardware)

### E1 — Template von ISO bauen
- **Tun:** ISO nach `deploy/pxe/iso/` legen; **Bereitstellung → Labor → „Template von ISO installieren"**
  (Name/ISO/Disk) → über **noVNC-Konsole** das OS installieren, dann herunterfahren.
- **Melden:** Konsole ging auf? Installation durch? VM-Name.
- **Ich prüfe:** VM lief (`/vm`-Liste), noVNC-Relay ok.

### E2 — Capture → DiskImage
- **Tun:** Template-Disk aufnehmen (Capture → Upload → finish).
- **Melden:** erscheint ein `DiskImage` mit Status `ready`?
- **Ich prüfe:** Image `ready`, Volumes/Manifest plausibel.

### E3 — Aktiv markieren + Grow-Policy
- **Tun:** Template **aktiv** markieren; Grow-Slider setzen (z. B. root 50 / var 30 / home 20).
- **Melden:** aktiv gesetzt + Policy gespeichert.
- **Ich prüfe:** genau ein aktives Template; `grow_policy` summiert auf 100.

### E4 — Zielhost planen + armen
- **Tun:** **Bereitstellen** → hostname/MAC/Netzwerk → „Host anlegen + armen".
- **Melden:** Host `planned` angelegt + RestoreJob `pending`?
- **Ich prüfe:** Agent `planned`, RestoreJob `pending` auf die MAC; **jetzt sollte DHCP angehen** (Gating).

### E5 — PXE-Test end-to-end
- **Tun:** **Labor → „PXE-Test starten"** → über noVNC zusehen: RAM-PE lädt → checkin → partclone-Restore
  + Multi-Volume-Wachstum (boot fix; root/var/home = Slider-%) → grub → offline-enrol → 1× reboot.
- **Melden:** Job-Verlauf `pending → running → done`? Ziel erscheint **enrolled**?
- **Ich prüfe:** RestoreJob done, Ziel enrolled, MAC wieder frei, DHCP nach Job-Ende wieder aus.

### E6 — DHCP-Modi (optional)
- **Tun:** mit `DHCP_MODE=proxy` **und** `full` bestätigen, dass beide das PE ausliefern.
- **Melden:** beides ok?
- **Ich prüfe:** Gating + Range in beiden Modi konsistent.

---

**Merke:** Nach jedem Punkt kurz zurückmelden — ich prüfe und gebe grün/rot, bevor du weitergehst.
Wenn ein Schritt rot ist, fixe ich, bevor es weitergeht.
