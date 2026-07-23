_LICENSE_STATE_MAP = {
    "OK": "OK",
    "WARNING": "WARN",
    "CRITICAL": "CRIT",
    "NOT_HARDWARE": "UNKNOWN",
    "NOT_APPLICABLE": "UNKNOWN",
}

def _fetch(ctx, url, username, password):
    return ctx.run([
        "curl", "-sk", "-u", "%s:%s" % (username, password),
        "-H", "Accept: application/json",
        url,
    ], mutates=False)

def _unknown(msg):
    return {"changed": False, "msg": msg,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

def main(ctx, params):
    host = params.get("host", "localhost")
    username = params.get("username", "admin")
    password = params.get("password", "")
    port = params.get("port", 443)
    base_url = "https://%s:%d/api/v1" % (host, port)

    fed_res = _fetch(ctx, "%s/management-gateways" % base_url, username, password)

    if fed_res.rc != 0:
        if params.get("_discover"):
            return {"changed": False, "msg": "discovered 0 appliances",
                    "data": {"discovery": []}}
        return _unknown("API unreachable: " + fed_res.stderr)

    fed_stdout = fed_res.stdout.strip()
    if not fed_stdout.startswith("{"):
        if params.get("_discover"):
            return {"changed": False, "msg": "discovered 0 appliances",
                    "data": {"discovery": []}}
        return _unknown("Unexpected API response from management-gateways")

    fed_data = json.decode(fed_stdout)
    members = fed_data.get("members", [])

    if params.get("_discover"):
        discovery = []
        for member in members:
            hostname = member.get("hostname", "")
            if hostname:
                discovery.append({
                    "item": hostname,
                    "params": {},
                    "metrics": [],
                })
        return {
            "changed": False,
            "msg": "discovered %d appliances" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")

    target_uuid = ""
    for member in members:
        if member.get("hostname", "") == item:
            target_uuid = member.get("uuid", member.get("applianceUUID", ""))
            break

    if not target_uuid:
        return _unknown("Appliance not found: " + item)

    dash_res = _fetch(
        ctx,
        "%s/management-gateways/%s/dashboard" % (base_url, target_uuid),
        username,
        password,
    )

    if dash_res.rc != 0:
        return _unknown("Dashboard API unreachable for " + item)

    dash_stdout = dash_res.stdout.strip()
    if not dash_stdout.startswith("{"):
        return _unknown("Unexpected dashboard API response for " + item)

    dash_data = json.decode(dash_stdout)

    license_status = dash_data.get("licenseStatus", "")
    license_status_str = dash_data.get("licenseStatusString", license_status)

    state = _LICENSE_STATE_MAP.get(license_status, "UNKNOWN")

    return {
        "changed": False,
        "msg": "Status: " + license_status_str,
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }