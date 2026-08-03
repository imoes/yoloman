# Cisco Meraki switch port statuses (read-only)
# Data source: Meraki Dashboard API is NOT reachable from the agent host.
# This check reproduces the *contract* of the Checkmk plugin; on hosts without
# the Meraki agent section it reports absence (empty discovery / UNKNOWN).

def _ok():
    return 0

def _warn():
    return 1

def _crit():
    return 2

def _unk():
    return 3

def _state_code(name):
    return {
        "OK": _ok(),
        "WARN": _warn(),
        "CRIT": _crit(),
        "UNKNOWN": _unk(),
    }.get(name, _unk())

# Checkmk default parameters for the check (State enum numeric values).
# check_default_parameters:
#   state_admin_change=1  (WARN)
#   state_disabled=0      (OK)
#   state_not_connected=0 (OK)
#   state_not_full_duplex=1 (WARN)
#   state_op_change=1     (WARN)
#   state_speed_change=1  (WARN)
def _default_params():
    return {
        "state_admin_change": _warn(),
        "state_disabled": _ok(),
        "state_not_connected": _ok(),
        "state_not_full_duplex": _warn(),
        "state_op_change": _warn(),
        "state_speed_change": _warn(),
    }

# discovery_default_parameters
def _default_discovery_params():
    return {
        "admin_port_states": ["up", "down"],
        "operational_port_states": ["up", "down"],
    }

def _port_id_of(raw):
    s = str(raw)
    if s.isdigit():
        return s
    return s

def _speed_summary(speed):
    if not speed:
        return "unknown"
    return speed

def _speed_as_int(speed):
    if not speed:
        return None
    parts = speed.split()
    if len(parts) != 2:
        return None
    raw_value = parts[0].replace(",", ".")
    unit = parts[1].lower()[0]
    if not raw_value.replace(".", "", 1).isdigit():
        return None
    value = float(raw_value)
    if unit == "k":
        return int(value + 1e3)
    if unit == "m":
        return int(value * 1e6)
    if unit == "g":
        return int(value * 1e9)
    if unit == "t":
        return int(value * 1e12)
    return None

# Mirror the Checkmk `match` on status.lower():
#   "connected"    -> oper_state "up"
#   "disconnected" -> oper_state "down"
#   _              -> oper_state "unknown"
def _oper_state(status):
    s = str(status).lower()
    if s == "connected":
        return "up"
    if s == "disconnected":
        return "down"
    return "unknown"

def _state_has_changed(is_state, was_state):
    if is_state != None and was_state == None:
        return True
    if is_state == was_state:
        return False
    return True

# No real on-host data source exists for the Meraki cloud API.
# We never fabricate Meraki data from /proc, /sys, ps, etc.
def _fetch_section():
    # Returns None to signal "section not available on this host".
    return None

def _worst_state(results):
    worst = _ok()
    for r in results:
        if r["code"] > worst:
            worst = r["code"]
    return worst

def main(ctx, params):
    if params.get("_discover"):
        section = _fetch_section()
        if not section:
            return {
                "changed": False,
                "msg": "no Meraki switch port statuses found on this host",
                "data": {"discovery": []},
            }
        dp = _default_discovery_params()
        admin_states = dp["admin_port_states"]
        oper_states = dp["operational_port_states"]
        out = []
        for item, port in section.items():
            admin_state = "up" if port.get("enabled") else "down"
            oper_state = _oper_state(port.get("status"))
            if admin_state in admin_states and oper_state in oper_states:
                out.append({
                    "item": item,
                    "params": {
                        "admin_state": admin_state,
                        "operational_state": oper_state,
                        "speed": _speed_summary(port.get("speed")),
                    },
                    "metrics": ["if_in_bps", "if_out_bps"],
                })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(out),
            "data": {"discovery": out},
        }

    item = params.get("item", "")
    section = _fetch_section()
    if not section or item not in section:
        return {
            "changed": False,
            "msg": "no Meraki switch port with item '%s' found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    port = section[item]
    cp = _default_params()
    for k, v in params.items():
        if k in cp:
            cp[k] = v

    results = []

    admin_state = "up" if port.get("enabled") else "down"
    if admin_state == "down":
        results.append({
            "code": _state_code("OK") if cp["state_disabled"] == _ok() else cp["state_disabled"],
            "summary": "(admin down)",
            "details": "Admin status: down",
        })
    else:
        results.append({"code": _ok(), "notice": "Admin status: up"})

    prior_admin = params.get("admin_state", "unknown")
    if _state_has_changed(admin_state, prior_admin):
        results.append({
            "code": cp["state_admin_change"],
            "summary": "changed admin %s -> %s" % (prior_admin, admin_state),
        })

    if admin_state == "down":
        st = _worst_state(results)
        return {
            "changed": False,
            "msg": "(admin down)",
            "data": {"state": "OK" if st == _ok() else "WARN" if st == _warn() else "CRIT" if st == _crit() else "UNKNOWN",
                     "metrics": {}, "details": "Admin status: down"},
        }

    oper = _oper_state(port.get("status"))
    if oper == "down":
        oper_code = cp["state_not_connected"]
    elif oper == "up":
        oper_code = _ok()
    else:
        oper_code = _unk()

    results.append({
        "code": oper_code,
        "summary": "(%s)" % oper,
        "details": "Operational status: %s" % oper,
    })

    prior_oper = params.get("operational_state", "unknown")
    if _state_has_changed(oper, prior_oper):
        results.append({
            "code": cp["state_op_change"],
            "summary": "changed %s -> %s" % (prior_oper, oper),
        })

    if oper in ("down", "unknown"):
        st = _worst_state(results)
        name = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}.get(st, "UNKNOWN")
        return {
            "changed": False,
            "msg": "(oper %s)" % oper,
            "data": {"state": name, "metrics": {}, "details": "Operational status: %s" % oper},
        }

    speed_summary = _speed_summary(port.get("speed"))
    speed_code = _ok() if speed_summary else _unk()
    results.append({
        "code": speed_code,
        "summary": "Speed: %s" % speed_summary,
    })

    prior_speed = params.get("speed", "unknown")
    if _state_has_changed(speed_summary, prior_speed):
        results.append({
            "code": cp["state_speed_change"],
            "summary": "changed %s -> %s" % (prior_speed, speed_summary),
        })

    metrics = {}
    traffic = port.get("trafficInKbps")
    if traffic:
        recv = traffic.get("recv")
        sent = traffic.get("sent")
        if recv != None:
            metrics["if_in_bps"] = recv
        if sent != None:
            metrics["if_out_bps"] = sent

    duplex = str(port.get("duplex", "")).lower()
    if duplex == "full":
        results.append({"code": _ok(), "notice": "Duplex: %s" % duplex})
    else:
        results.append({"code": cp["state_not_full_duplex"], "notice": "Duplex: %s" % duplex})

    results.append({"code": _ok(), "notice": "Clients: %s" % port.get("clientCount", 0)})

    if port.get("isUplink"):
        results.append({"code": _ok(), "summary": "Uplink", "details": "Uplink: yes"})
    else:
        results.append({"code": _ok(), "notice": "Uplink: no"})

    power = port.get("powerUsageInWh")
    if power != None:
        results.append({"code": _ok(), "summary": "Power usage: %s Wh" % power})

    st = _worst_state(results)
    name = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}.get(st, "UNKNOWN")

    return {
        "changed": False,
        "msg": "Interface %s" % item,
        "data": {
            "state": name,
            "metrics": metrics,
            "details": "",
        },
    }