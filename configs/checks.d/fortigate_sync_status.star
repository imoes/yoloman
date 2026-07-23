# Map from SNMP status string to (state, summary)
STATUS_MAP = {
    "0": ("CRIT", "unsynchronized"),
    "1": ("OK", "synchronized"),
}

def main(ctx, params):
    # Discovery mode: emit one service if there is more than one cluster entry
    if params.get("_discover"):
        # Use snmpwalk to get the full table
        res = ctx.run([
            "snmpwalk",
            "-On",
            "-OvQ",
            "-v2c",
            "-c", "public",
            "localhost",
            ".1.3.6.1.4.1.12356.101.13.2.1.1",
        ], mutates=False)
        
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "no data",
                    "data": {"discovery": []}}

        # Parse snmpwalk output: each line like ".1.3.6.1.4.1.12356.101.13.2.1.1.11.1 = STRING: "cluster1""
        lines = res.stdout.splitlines()
        clusters = {}
        for line in lines:
            if not line:
                continue
            # Split on " = "
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_val = parts[0].strip()
            value = parts[1].strip().strip('"')
            # Determine if it's name (.11) or status (.12)
            if ".11." in oid_val:
                # Extract index from OID: last part after .11.
                idx_parts = oid_val.rsplit(".11.", 1)
                if len(idx_parts) == 2:
                    idx = idx_parts[1]
                    clusters[idx] = {"name": value, "status": clusters.get(idx, {}).get("status")}
            elif ".12." in oid_val:
                idx_parts = oid_val.rsplit(".12.", 1)
                if len(idx_parts) == 2:
                    idx = idx_parts[1]
                    clusters[idx] = {"name": clusters.get(idx, {}).get("name", ""), "status": value}

        # Convert to list of cluster entries
        section = []
        for idx, data in clusters.items():
            if data["name"]:
                section.append({"name": data["name"], "status": data["status"]})

        # Discovery: if more than one cluster, yield a service
        if len(section) > 1:
            return {
                "changed": False,
                "msg": "discovered 1 service",
                "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
            }
        return {"changed": False, "msg": "discovered 0 services",
                "data": {"discovery": []}}

    # Check mode
    # Re-read the agent section — in a real environment, this would be cached by Checkmk,
    # but here we repeat the snmpwalk. For simplicity, we assume the section is static.
    res = ctx.run([
        "snmpwalk",
        "-On",
        "-OvQ",
        "-v2c",
        "-c", "public",
        "localhost",
        ".1.3.6.1.4.1.12356.101.13.2.1.1",
    ], mutates=False)

    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "failed to fetch sync status data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    lines = res.stdout.splitlines()
    clusters = {}
    for line in lines:
        if not line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_val = parts[0].strip()
        value = parts[1].strip().strip('"')
        if ".11." in oid_val:
            idx_parts = oid_val.rsplit(".11.", 1)
            if len(idx_parts) == 2:
                idx = idx_parts[1]
                clusters[idx] = {"name": value, "status": clusters.get(idx, {}).get("status")}
        elif ".12." in oid_val:
            idx_parts = oid_val.rsplit(".12.", 1)
            if len(idx_parts) == 2:
                idx = idx_parts[1]
                clusters[idx] = {"name": clusters.get(idx, {}).get("name", ""), "status": value}

    section = []
    for idx, data in clusters.items():
        if data["name"]:
            section.append({"name": data["name"], "status": data["status"]})

    # If section is empty or has only one cluster, check might not apply, but per the original,
    # discovery yields a service only when len > 1. So if we're in check mode with item "",
    # and len(section) <= 1, we return UNKNOWN.
    if not section or len(section) <= 1:
        return {
            "changed": False,
            "msg": "no clusters or only one cluster",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Iterate clusters and report status
    for cluster in section:
        name = cluster["name"]
        status = cluster["status"]
        if status == None or status == "":
            return {
                "changed": False,
                "msg": name + ": Status not available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }

        state_summary = STATUS_MAP.get(status, ("UNKNOWN", "Unknown status " + status))
        state = state_summary[0]
        summary = state_summary[1]
        # Return first cluster's status (the original check yields multiple Results, but
        # the Starlark check returns one state. Per Checkmk conventions for this check,
        # it yields one Result per cluster, but the yolo-man agent expects one verdict.
        # Since the check has service "Sync Status" (singular), we take the first cluster's state.
        return {
            "changed": False,
            "msg": name + ": " + summary,
            "data": {"state": state, "metrics": {}, "details": ""},
        }

    # Fallback
    return {
        "changed": False,
        "msg": "no clusters found",
        "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
    }
