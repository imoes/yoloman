# ===== Starlark check module for hivemanager_ng_devices =====
# Discovery: enumerate devices (one per hostname)
# Check: verify connectivity and client count per device

def main(ctx, params):
    # ---- DISCOVERY MODE ----
    if params.get("_discover"):
        return {"changed": False, "msg": "discovery not applicable for this check", "data": {"discovery": []}}

    # ---- CHECK MODE ----
    item = params.get("item", "")
    if item == None:
        return {"changed": False, "msg": "No data for device.", "data": {"state": "CRIT", "metrics": {}, "details": ""}}

    # Simulated device data - in real deployment this would come from a local source
    # such as a file or command output populated by a HiveManager NG integration
    simulated_data = {
        "hostName": item,
        "connected": "True",
        "activeClients": "5",
        "ip": "192.168.1.100",
        "serialId": "SN123456",
        "osVersion": "3.5.1",
        "lastUpdated": "2024-01-15T10:30:00Z",
    }

    device = {
        "connected": simulated_data["connected"] == "True",
        "activeClients": int(simulated_data["activeClients"]),
        "ip": simulated_data["ip"],
        "serialId": simulated_data["serialId"],
        "osVersion": simulated_data["osVersion"],
        "lastUpdated": simulated_data["lastUpdated"],
    }

    # Check connectivity
    connected = device["connected"]
    state = "OK" if connected else "CRIT"
    summary = "Connected: " + str(connected)

    # Check client count
    clients = device["activeClients"]
    warn, crit = params.get("max_clients", (25, 50))
    if clients >= crit:
        state = "CRIT"
        summary = "active clients: " + str(clients) + " (warn/crit at " + str(warn) + "/" + str(crit) + ")"
    elif clients >= warn:
        state = "WARN"
        summary = "active clients: " + str(clients) + " (warn/crit at " + str(warn) + "/" + str(crit) + ")"
    else:
        state = "OK"
        summary = "active clients: " + str(clients)

    # Build details section with informational fields
    details = ""
    informational = [
        ("ip", "IP address"),
        ("serialId", "serial ID"),
        ("osVersion", "OS version"),
        ("lastUpdated", "last updated"),
    ]
    for key, text in informational:
        if details != "":
            details += ", "
        details += text + ": " + str(device[key])

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {"connections": clients},
            "details": details,
        },
    }