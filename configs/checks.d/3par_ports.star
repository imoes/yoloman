# ===== check plugin: checkmk.3par_ports =====
# Translated from Checkmk's hpe_3par_ports check plugin.
#
# This check monitors HPE 3PAR storage array ports (Fibre Channel, iSCSI, etc).
# On a Checkmk system the data comes from the 3PAR array via the hpe3par
# CLI / REST API. On this agent there is no 3PAR array reachable, so the
# honest translation is: if we can talk to the 3PAR CLI, parse its port
# listing; otherwise the check does not apply (empty discovery / UNKNOWN).
#
# The 3PAR CLI (`showport` / `showvlun`) is the canonical on-host source
# that the Checkmk agent plugin shells out to. We probe for it here.

CLI_3PAR = "3paradm"

PROTOCOLS = {
    1: "FC",
    2: "iSCSI",
    3: "FCOE",
    4: "IP",
    5: "SAS",
    6: "NVMe",
}

LINKS = {
    1: "CONFIG_WAIT",
    2: "ALPA_WAIT",
    3: "LOGIN_WAIT",
    4: "READY",
    5: "LOSS_SYNC",
    6: "ERROR_STATE",
    7: "XXX",
    8: "NONPARTICIPATE",
    9: "COREDUMP",
    10: "OFFLINE",
    11: "FWDEAD",
    12: "IDLE_FOR_RESET",
    13: "DHCP_IN_PROGRESS",
    14: "PENDING_RESET",
}

MODES = {
    1: "SUSPENDED",
    2: "TARGET",
    3: "INITIATOR",
    4: "PEER",
}

FAILOVERS = {
    1: "NONE",
    2: "FAILOVER_PENDING",
    3: "FAILED_OVER",
    4: "ACTIVE",
    5: "ACTIVE_DOWN",
    6: "ACTIVE_FAILED",
    7: "FAILBACK_PENDING",
}

DEFAULT_LEVELS = {
    "1_link": 1,
    "2_link": 1,
    "3_link": 1,
    "4_link": 0,
    "5_link": 2,
    "6_link": 2,
    "7_link": 1,
    "8_link": 0,
    "9_link": 1,
    "10_link": 1,
    "11_link": 1,
    "12_link": 1,
    "13_link": 1,
    "14_link": 1,
    "1_fail": 0,
    "2_fail": 2,
    "3_fail": 2,
    "4_fail": 2,
    "5_fail": 2,
    "6_fail": 2,
    "7_fail": 1,
}


def _parse_port_json(text):
    """Parse the JSON output of `3paradm showport -d` (or equivalent)
    and return a dict of port-name -> port dict, mirroring the
    Checkmk plugin's in-memory section structure."""
    if text == None or text.strip() == "":
        return {}
    data = json.decode(text)
    members = data.get("members", []) if type(data) == "dict" else []
    ports = {}
    for p in members:
        proto = p.get("protocol")
        if PROTOCOLS.get(proto) == None:
            continue
        state = p.get("linkState")
        mode = p.get("mode")
        failover = p.get("failoverState")
        pos = p.get("portPos", {})
        node = pos.get("node")
        slot = pos.get("slot")
        cardPort = pos.get("cardPort")
        proto_name = PROTOCOLS.get(proto, "UNKNOWN")
        name = "%s Node %s Slot %s Port %s" % (proto_name, node, slot, cardPort)
        ports.setdefault(name, {
            "name": name,
            "type": p.get("type"),
            "label": p.get("label"),
            "state": state,
            "translated_state": LINKS.get(state),
            "protocol": proto,
            "portWWN": p.get("portWWN"),
            "mode": mode,
            "translated_mode": MODES.get(mode),
            "failoverState": failover,
            "translated_failover": FAILOVERS.get(failover),
        })
    return ports


def _state_to_name(level):
    """Map Checkmk State numeric levels (0=OK, 1=WARN, 2=CRIT, 3=UNKNOWN)
    to the string names used in the returned data."""
    return {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}.get(level, "UNKNOWN")


def main(ctx, params):
    # ---- Discovery mode ----
    if params.get("_discover"):
        # Probe for the 3PAR CLI / array tooling. rc==127 => not installed.
        res = ctx.run([CLI_3PAR, "--version"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "no HPE 3PAR array / CLI found",
                    "data": {"discovery": []}}

        # Fetch port listing as JSON. The 3PAR CLI `showport -d` (or the
        # equivalent REST endpoint) yields JSON with a "members" array.
        res = ctx.run([CLI_3PAR, "showport", "-d"], mutates=False)
        ports = _parse_port_json(res.stdout)
        discovery = []
        for name in ports:
            port = ports[name]
            # Skip FREE ports (type == 3), mirroring the plugin's filter
            if port["type"] == 3:
                continue
            discovery.append({
                "item": name,
                "params": dict(DEFAULT_LEVELS),
                "metrics": ["port_link_state", "port_failover_state"],
            })
        return {"changed": False,
                "msg": "discovered %d 3PAR ports" % len(discovery),
                "data": {"discovery": discovery}}

    # ---- Check mode ----
    item = params.get("item", "")

    # Re-confirm the 3PAR CLI is present (absence => UNKNOWN, not OK).
    probe = ctx.run([CLI_3PAR, "--version"], mutates=False)
    if probe.rc != 0:
        return {"changed": False,
                "msg": "no HPE 3PAR array / CLI found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    res = ctx.run([CLI_3PAR, "showport", "-d"], mutates=False)
    ports = _parse_port_json(res.stdout)
    port = ports.get(item)
    if port == None:
        return {"changed": False,
                "msg": "no such 3PAR port: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # A FREE port (type == 3) is not a real service — report UNKNOWN.
    if port["type"] == 3:
        return {"changed": False,
                "msg": "port %s is FREE" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    level = 0  # OK by default
    lines = []

    if port["label"]:
        lines.append("Label: %s" % port["label"])

    # Link state: warn/crit come from params via "<state>_link"
    if port["state"] != None and port["translated_state"] != None:
        level_name = "%s_link" % port["state"]
        lvl = params.get(level_name, DEFAULT_LEVELS.get(level_name, 0))
        # In Checkmk State is OK=0, WARN=1, CRIT=2, UNKNOWN=3.
        # The plugin uses the configured level directly.
        level = max(level, lvl)
        lines.append("%s (link-level %d)" % (port["translated_state"], lvl))

    if port["portWWN"]:
        lines.append("portWWN: %s" % port["portWWN"])

    if port["mode"] != None:
        lines.append("Mode: %s" % port["translated_mode"])

    if port["failoverState"] != None and port["translated_failover"] != None:
        fl_name = "%s_fail" % port["failoverState"]
        flvl = params.get(fl_name, DEFAULT_LEVELS.get(fl_name, 0))
        level = max(level, flvl)
        lines.append("Failover: %s (fail-level %d)" % (port["translated_failover"], flvl))

    state = _state_to_name(level)
    metrics = {}
    if port["state"] != None:
        metrics["port_link_state"] = port["state"]
    if port["failoverState"] != None:
        metrics["port_failover_state"] = port["failoverState"]

    msg = "; ".join(lines) if lines else item
    return {"changed": False,
            "msg": msg,
            "data": {"state": state, "metrics": metrics,
                     "details": "; ".join(lines)}}