def monitoring_state_for_operability(code):
    states = {
        "0": "CRIT",
        "1": "OK",
        "2": "CRIT",
        "3": "CRIT",
        "4": "WARN",
        "5": "CRIT",
        "6": "OK",
        "7": "CRIT",
        "8": "CRIT",
        "9": "WARN",
        "10": "WARN",
        "11": "WARN",
        "12": "CRIT",
        "13": "WARN",
        "14": "WARN",
        "51": "WARN",
        "52": "WARN",
        "81": "WARN",
        "82": "CRIT",
        "83": "CRIT",
        "84": "WARN",
        "100": "WARN",
        "101": "WARN",
        "102": "CRIT",
        "103": "WARN",
        "104": "CRIT",
        "105": "WARN",
        "106": "WARN",
        "107": "OK",
        "108": "WARN",
    }
    return states.get(code, "CRIT")

STATE_OK = "OK"
STATE_WARN = "WARN"
STATE_CRIT = "CRIT"
STATE_UNKNOWN = "UNKNOWN"

FAN_BASE = ".1.3.6.1.4.1.9.9.719.1.15.12.1"
FAN_DN_COL = "2"
FAN_OPER_COL = "10"

FAULT_BASE = ".1.3.6.1.4.1.9.9.719.1.15.12.1"
FAULT_DN_COL = "2"


def severity_to_state(sev):
    if sev == "5" or sev == "6":
        return STATE_CRIT
    if sev == "3" or sev == "4":
        return STATE_WARN
    return STATE_OK


def highest_state(states):
    rank = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    worst = "OK"
    for s in states:
        if rank.get(s, 0) > rank.get(worst, 0):
            worst = s
    return worst

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        walk_dn = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, "%s.%s" % (FAN_BASE, FAN_DN_COL)], mutates=False)
        if walk_dn.rc != 0:
            if walk_dn.rc == 127:
                return {"changed": False, "msg": "snmpwalk not installed", "data": {"discovery": [], "host_labels": {}}}
            return {"changed": False, "msg": "SNMP walk failed", "data": {"discovery": [], "host_labels": {}}}

        dn_map = {}
        for line in walk_dn.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            val = parts[1].strip().strip('"')
            idx = oid[len("%s.%s" % (FAN_BASE, FAN_DN_COL)) + 1:]
            if idx == "":
                continue
            dn_map[idx] = val

        items = []
        for idx in dn_map:
            dn = dn_map[idx]
            name = " ".join(dn.split("/")[2:])
            items.append({"item": name, "params": {}, "metrics": []})

        return {"changed": False, "msg": "discovered %d fans" % len(items), "data": {"discovery": items, "host_labels": {}}}

    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "no fan item specified", "data": {"state": STATE_UNKNOWN, "metrics": {}, "details": ""}}

    walk_dn = ctx.run(["snmpwalk", "-v2c", "-c", community, "-Oqn", host, "%s.%s" % (FAN_BASE, FAN_DN_COL)], mutates=False)
    if walk_dn.rc != 0 or not walk_dn.stdout.strip():
        return {"changed": False, "msg": "no fan data found", "data": {"state": STATE_UNKNOWN, "metrics": {}, "details": ""}}

    dn_map = {}
    for line in walk_dn.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        val = parts[1].strip().strip('"')
        idx = oid[len("%s.%s" % (FAN_BASE, FAN_DN_COL)) + 1:]
        dn_map[idx] = val

    target_idx = None
    for idx in dn_map:
        dn = dn_map[idx]
        name = " ".join(dn.split("/")[2:])
        if name == item:
            target_idx = idx
            break

    if target_idx == None:
        return {"changed": False, "msg": "fan not found: " + item, "data": {"state": STATE_UNKNOWN, "metrics": {}, "details": ""}}

    op_res = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, "%s.%s.%s" % (FAN_BASE, FAN_OPER_COL, target_idx)], mutates=False)
    if op_res.rc != 0:
        return {"changed": False, "msg": "cannot read operability for " + item, "data": {"state": STATE_UNKNOWN, "metrics": {}, "details": ""}}

    oper_val = op_res.stdout.strip().strip('"')
    op_state = monitoring_state_for_operability(oper_val)

    return {"changed": False, "msg": "Status: operability %s (%s)" % (oper_val, op_state), "data": {"state": op_state, "metrics": {}, "details": ""}}