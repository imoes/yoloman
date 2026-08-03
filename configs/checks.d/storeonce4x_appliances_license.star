def _state_ok():
    return "OK"

def _state_warn():
    return "WARN"

def _state_crit():
    return "CRIT"

def _state_unknown():
    return "UNKNOWN"

_APP_STATE_MAP = {"Reachable": _state_ok()}

_LICENSE_MAP = {
    "OK": _state_ok(),
    "WARNING": _state_warn(),
    "CRITICAL": _state_crit(),
    "NOT_HARDWARE": _state_unknown(),
    "NOT_APPLICABLE": _state_unknown(),
}

def main(ctx, params):
    if params.get("_discover"):
        probe = ctx.run(
            ["storeonce4x-appliances", "federation"],
            mutates=False,
        )
        if probe.rc == 127 or probe.rc != 0 or not probe.stdout:
            return {"changed": False, "msg": "StoreOnce not present on this host",
                    "data": {"discovery": [], "host_labels": {}}}

        federation = json.decode(probe.stdout)
        members = []
        if federation != None:
            m = federation.get("members", [])
            if m != None:
                members = m

        probe2 = ctx.run(
            ["storeonce4x-appliances", "dashboard"],
            mutates=False,
        )
        dash_list = []
        if probe2.rc == 0 and probe2.stdout:
            dash_list = json.decode(probe2.stdout)
            if dash_list == None:
                dash_list = []

        dash_by_host = {}
        for d in dash_list:
            if d == None:
                continue
            hn = d.get("hostname")
            if hn != None:
                dash_by_host[hn] = d

        discovery = []
        for member in members:
            if member == None:
                continue
            hostname = member.get("hostname")
            if hostname == None:
                continue
            state_str = member.get("applianceStateString", "")
            cmk_state = _APP_STATE_MAP.get(state_str, _state_unknown())
            dashboard = dash_by_host.get(hostname, None)

            svc_labels = {}
            product = member.get("productName", "")
            if product != None and product != "":
                svc_labels["storeonce/product"] = str(product)
            if dashboard != None:
                lic_status = dashboard.get("licenseStatus", None)
                if lic_status != None:
                    svc_labels["storeonce/license"] = str(lic_status)

            discovery.append({
                "item": hostname,
                "params": {},
                "metrics": ["license_state"],
                "service_labels": svc_labels,
            })

        host_labels = {"cmk/storeonce4x": "present"}
        return {"changed": False,
                "msg": "discovered %d appliances" % len(discovery),
                "data": {"discovery": discovery, "host_labels": host_labels}}

    item = params.get("item", "")

    p1 = ctx.run(["storeonce4x-appliances", "federation"], mutates=False)
    if p1.rc == 127 or p1.rc != 0 or not p1.stdout:
        return {"changed": False,
                "msg": "StoreOnce not found on host",
                "data": {"state": _state_unknown(), "metrics": {},
                         "details": "storeonce4x-appliances federation data unavailable"}}

    federation = json.decode(p1.stdout)
    members = []
    if federation != None:
        m = federation.get("members", [])
        if m != None:
            members = m

    host = None
    for member in members:
        if member == None:
            continue
        if member.get("hostname") == item:
            host = member
            break

    p2 = ctx.run(["storeonce4x-appliances", "dashboard"], mutates=False)
    dash_list = []
    if p2.rc == 0 and p2.stdout:
        dash_list = json.decode(p2.stdout)
        if dash_list == None:
            dash_list = []

    dash = None
    for d in dash_list:
        if d == None:
            continue
        if d.get("hostname") == item:
            dash = d
            break

    if host == None and dash == None:
        return {"changed": False,
                "msg": "no such appliance: %s" % item,
                "data": {"state": _state_unknown(), "metrics": {},
                         "details": "appliance %s not found" % item}}

    lic_str = ""
    state = _state_unknown()
    if dash != None:
        lic_status = dash.get("licenseStatus", None)
        lic_str = dash.get("licenseStatusString", "")
        state = _LICENSE_MAP.get(lic_status, _state_unknown())

    summary = "Status: %s" % lic_str if lic_str != None else "Status: unknown"
    return {"changed": False,
            "msg": summary,
            "data": {"state": state, "metrics": {}, "details": ""}}