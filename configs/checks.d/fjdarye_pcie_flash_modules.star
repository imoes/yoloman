# Top-level constants
FJDARYE_SUPPORTED_DEVICE = ".1.3.6.1.4.1.211.1.21.1.150"
BASE_OID = FJDARYE_SUPPORTED_DEVICE + ".2.22.2.1"

MAP_STATES = {
    "1": "OK",
    "2": "CRIT",
    "3": "WARN",
    "4": "CRIT",
    "5": "OK",
    "6": "UNKNOWN",
}


def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: fetch all modules and enumerate those with valid status
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
            params.get("host", "localhost"),
            BASE_OID + ".2"   # fjdaryPfmItemId
        ], mutates=False)
        if res.rc != 0:
            fail("SNMP walk failed: " + res.stderr)

        # Parse output: lines look like ".1.3.6.1.4.1.211.1.21.1.150.2.22.2.1.2.0 = INTEGER: 1996492800"
        item_ids = []
        for line in res.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            suffix = parts[0].rsplit(".", 1)[-1]   # e.g., "0"
            value_part = parts[1].strip()
            if value_part.startswith("INTEGER: "):
                item_ids.append(suffix)

        # Now fetch status and health for all modules by walking their OIDs
        status_oid = BASE_OID + ".3"
        health_oid = BASE_OID + ".5"

        res_status = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
            params.get("host", "localhost"), status_oid
        ], mutates=False)
        res_health = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"), "-On",
            params.get("host", "localhost"), health_oid
        ], mutates=False)

        if res_status.rc != 0 or res_health.rc != 0:
            fail("SNMP fetch failed")

        # Build mapping item_id -> status, health_lifetime
        status_map = {}
        for line in res_status.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            suffix = parts[0].rsplit(".", 1)[-1]
            value_part = parts[1].strip()
            if value_part.startswith("INTEGER: "):
                status_map[suffix] = value_part.split(": ")[1]

        health_map = {}
        for line in res_health.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) < 2:
                continue
            suffix = parts[0].rsplit(".", 1)[-1]
            value_part = parts[1].strip()
            if value_part.startswith("INTEGER: "):
                val_str = value_part.split(": ")[1]
                health_map[suffix] = float(val_str) if val_str.lstrip("-").isdigit() else float(val_str)

        # Assemble discovery items: exclude status "4" (invalid)
        out = []
        for item_id in item_ids:
            status = status_map.get(item_id, "6")
            if status != "4":
                out.append({
                    "item": item_id,
                    "params": {"health_lifetime_perc": [20.0, 15.0]},
                    "metrics": ["health_lifetime"]
                })

        return {
            "changed": False,
            "msg": "discovered %d PCIe flash modules" % len(out),
            "data": {"discovery": out}
        }

    # Check mode: process single item
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    # Fetch status and health for this specific item via snmpget
    status_oid = BASE_OID + ".3." + item
    health_oid = BASE_OID + ".5." + item

    res_status = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host, status_oid
    ], mutates=False)
    res_health = ctx.run([
        "snmpget", "-v2c", "-c", community, "-On", host, health_oid
    ], mutates=False)

    # Handle missing item gracefully
    if res_status.rc != 0 or res_health.rc != 0:
        return {
            "changed": False,
            "msg": "item %s not found or unreachable" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse status
    status = None
    for line in res_status.stdout.splitlines():
        if line.find(" = INTEGER: ") != -1:
            status = line.strip().split(" = INTEGER: ")[1]
            break
    if status == None:
        status = "6"

    # Parse health
    health = -1.0
    for line in res_health.stdout.splitlines():
        if line.find(" = INTEGER: ") != -1:
            val_str = line.strip().split(" = INTEGER: ")[1]
            health = float(val_str) if val_str.lstrip("-").isdigit() else float(val_str)
            break

    # Determine state from status mapping
    state = MAP_STATES.get(status, "UNKNOWN")
    summary_parts = ["Status: " + {
        "1": "normal", "2": "alarm", "3": "warning", "4": "invalid",
        "5": "maintenance", "6": "undefined"
    }.get(status, "undefined")]

    # Health lifetime check
    if health < 0:
        summary_parts.append("Health lifetime cannot be obtained")
    else:
        warn, crit = params.get("health_lifetime_perc", [20.0, 15.0])
        # Lower threshold check: CRIT if health <= crit, WARN if health <= warn
        if health <= crit:
            state = "CRIT"
        elif health <= warn:
            state = "WARN"

        summary_parts.append("Health lifetime: %f%%" % health)

    summary = ", ".join(summary_parts)

    metrics = {"health_lifetime": health} if health >= 0 else {}

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }
