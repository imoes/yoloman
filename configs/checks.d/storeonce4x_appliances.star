_APP_STATE_MAP = {
    "Reachable": "OK",
}

def _curl_json(ctx, url, user, password):
    res = ctx.run([
        "curl", "-sk",
        "-u", user + ":" + password,
        "-H", "Accept: application/json",
        "--connect-timeout", "10",
        url,
    ], mutates=False)
    if res.rc != 0:
        return None
    stdout = res.stdout.strip()
    if not stdout:
        return None
    if not stdout.startswith("{") and not stdout.startswith("["):
        return None
    return json.decode(stdout)

def main(ctx, params):
    host = params.get("host", "localhost")
    user = params.get("user", "admin")
    password = params.get("password", "")
    port = str(params.get("port", 443))
    item = params.get("item", "")

    base_url = "https://" + host + ":" + port
    fed_url = base_url + "/rest/storeonce/v4/management-services/federation"

    fed_data = _curl_json(ctx, fed_url, user, password)

    if fed_data == None:
        if params.get("_discover"):
            return {
                "changed": False,
                "msg": "discovered 0 appliances",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "cannot reach federation endpoint on " + host,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    members = fed_data.get("members", [])

    if params.get("_discover"):
        disc = []
        for member in members:
            hostname = member.get("hostname", "")
            if hostname:
                disc.append({
                    "item": hostname,
                    "params": {},
                    "metrics": [],
                })
        return {
            "changed": False,
            "msg": "discovered %d appliances" % len(disc),
            "data": {"discovery": disc},
        }

    # Check mode: find the federation member matching item
    member_data = None
    for member in members:
        if member.get("hostname", "") == item:
            member_data = member
            break

    if member_data == None:
        return {
            "changed": False,
            "msg": "appliance not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    appliance_state = member_data.get("applianceStateString", "Unknown")
    state = _APP_STATE_MAP.get(appliance_state, "UNKNOWN")
    serial_number = member_data.get("serialNumber", "N/A")
    product_name = member_data.get("productName", "N/A")

    # softwareVersion lives in the per-appliance dashboard section
    member_addr = member_data.get("address", host)
    if not member_addr:
        member_addr = host
    dash_url = "https://" + member_addr + ":" + port + "/rest/storeonce/v4/management-services/dashboard"
    dash_data = _curl_json(ctx, dash_url, user, password)

    software_version = "N/A"
    if dash_data != None:
        software_version = dash_data.get("softwareVersion", "N/A")
        dash_product = dash_data.get("productName", "")
        if dash_product:
            product_name = dash_product

    msg = "State: %s, Serial Number: %s, Software version: %s, Product Name: %s" % (
        appliance_state,
        serial_number,
        software_version,
        product_name,
    )

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }