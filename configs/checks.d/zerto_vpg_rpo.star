# ===== checkmk.zerto_vpg_rpo — read-only Starlark translation =====
# Zerto Virtual Protection Group RPO state monitor.
#
# Zerto exposes its data through a management server (ZMS) over a REST API on
# TCP/443 (typically https://<zms>:443). There is no on-host file, CLI tool or
# /proc entry that carries the VPG RPO state on a regular Linux host — the
# Checkmk "agent" for Zerto is a *special agent* that talks HTTP(S) to the ZMS.
#
# Per the translation contract, this module therefore speaks to the SAME
# underlying source the Checkmk special agent uses: the ZMS REST API. We do
# NOT wrap Checkmk, and we do NOT fall back to any local /proc or /sys file
# (there is no stand-in for a remote storage-management appliance).

# Numeric RPO state -> (verdict, human summary) exactly as the Checkmk source.
MAP_RPO_STATES = {
    "0": ("WARN", "VPG is initializing"),
    "1": ("OK", "Meeting SLA specification"),
    "2": ("CRIT", "Not meeting SLA specification for RPO SLA and journal history"),
    "3": ("CRIT", "Not meeting SLA specification for RPO SLA"),
    "4": ("CRIT", "Not meeting SLA specification for journal history"),
    "5": ("WARN", "VPG is in a failover operation"),
    "6": ("WARN", "VPG is in a move operation"),
    "7": ("WARN", "VPG is being deleted"),
    "8": ("WARN", "VPG has been recovered"),
}

# ZMS REST endpoint that the official special agent queries for VPG RPO state.
VPGS_PATH = "/v1/vpgs/rto"


def _zms_url(params):
    """Build the base https URL of the ZMS from params with sane defaults."""
    host = params.get("host", "localhost")
    port = params.get("port", 443)
    return "https://%s:%s" % (host, port)


def _vpgs_from_api(ctx, params):
    """Fetch the VPG list from the ZMS REST API and return {vpg: {state, actual_rpo}}.

    Mirrors the Checkmk special agent's data source (HTTP GET to the ZMS)
    rather than any local file. Returns None on failure/empty.
    """
    url = _zms_url(params) + VPGS_PATH
    token = params.get("token", "")

    # Prefer a real HTTP probe via curl. curl is the only portable on-host way
    # to reach the ZMS REST API; if it is absent (rc 127) the product is not
    # on this host in any meaningful form here, so we report absence.
    argv = ["curl", "-sk", "-H", "Content-Type: application/json"]
    if token != "":
        argv = argv + ["-H", "Authorization: Bearer " + token]
    argv = argv + ["-w", "\\n%{http_code}", url]

    res = ctx.run(argv, mutates=False)
    if res.rc == 127:
        return None  # curl not present -> cannot reach the ZMS
    if res.rc != 0:
        return None

    raw = res.stdout
    # curl -w appends "\n<http_code>" as the final line.
    lines = raw.splitlines()
    if len(lines) < 2:
        return None
    http_code = lines[-1].strip()
    body = "\n".join(lines[:-1])
    if http_code != "200" or body == "" or body == "[]":
        return None

    try_parse = json.decode(body)
    if type(try_parse) != "list":
        return None

    out = {}
    for entry in try_parse:
        if type(entry) != "dict":
            continue
        name = entry.get("Name", entry.get("name", ""))
        if name == "":
            continue
        state = str(entry.get("RpoState", entry.get("rpo_state", "0")))
        actual_rpo = str(entry.get("ActualRPO", entry.get("actual_rpo", "0")))
        out[name] = {"state": state, "actual_rpo": actual_rpo}
    return out


def main(ctx, params):
    # ---- DISCOVERY ----
    if params.get("_discover"):
        section = _vpgs_from_api(ctx, params)
        discovery = []
        for vpg in sorted(section.keys()) if section else []:
            # Each VPG becomes one service; metrics it exposes.
            discovery.append({
                "item": vpg,
                "params": {},
                "metrics": ["rpo_seconds"],
                "service_labels": {},
            })
        return {
            "changed": False,
            "msg": "discovered %d VPGs" % len(discovery),
            "data": {"discovery": discovery},
        }

    # ---- CHECK (single item) ----
    item = params.get("item", "")
    section = _vpgs_from_api(ctx, params)

    if section == None:
        return {
            "changed": False,
            "msg": "ZMS API unreachable or curl not available; cannot query Zerto VPGs",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    data = section.get(item)
    if data == None:
        return {
            "changed": False,
            "msg": "VPG '%s' not found on the ZMS" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state_str, vpg_info = MAP_RPO_STATES.get(data.get("state", ""), ("UNKNOWN", "Unknown"))
    actual_rpo_str = data.get("actual_rpo", "0")
    rpo_val = float(actual_rpo_str) if actual_rpo_str.replace(".", "", 1).isdigit() else 0.0

    if state_str == "UNKNOWN":
        state_str = "UNKNOWN"

    return {
        "changed": False,
        "msg": "VPG Status: %s" % vpg_info,
        "data": {
            "state": state_str,
            "metrics": {"rpo_seconds": rpo_val},
            "details": "VPG Status: %s\nActual RPO: %s seconds\nState code: %s" % (
                vpg_info, actual_rpo_str, data.get("state", "")),
        },
    }