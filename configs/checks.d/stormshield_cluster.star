# Map for sync status (from Checkmk plugin)
SYNC_NAME_MAPPING = {
    "1": "Synced",
    "0": "Not Synced",
    "-1": "Unknown / Error",
    "": "Unknown / Error",
}

SYNC_STATUS_MAPPING = {
    "1": "OK",
    "0": "CRIT",
    "-1": "UNKNOWN",
    "": "UNKNOWN",
}


def main(ctx, params):
    # Discovery mode: yield single service for HA Status
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]}
        }

    # Check mode: fetch SNMP data
    res = ctx.run([
        "snmpget",
        "-On",
        "-v2c",
        "-c",
        "public",
        "localhost",
        ".1.3.6.1.4.1.11256.1.11.1.0",
        ".1.3.6.1.4.1.11256.1.11.2.0",
        ".1.3.6.1.4.1.11256.1.11.3.0",
        ".1.3.6.1.4.1.11256.1.11.5.0",
        ".1.3.6.1.4.1.11256.1.11.6.0",
        ".1.3.6.1.4.1.11256.1.11.8.0",
    ], mutates=False)

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse snmpget output: expect lines like "OID = value"
    lines = res.stdout.splitlines()
    if len(lines) < 6:
        return {
            "changed": False,
            "msg": "insufficient SNMP data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Extract values from SNMP output
    def get_value(line):
        parts = line.split(" = ")
        if len(parts) < 2:
            return ""
        return parts[1].strip().strip('"')

    number = get_value(lines[0])
    not_replying_str = get_value(lines[1])
    active = get_value(lines[2])
    eth_links = get_value(lines[3])
    faulty_links_str = get_value(lines[4])
    sync = get_value(lines[5])

    # Parse integers safely (guard instead of try/except)
    not_replying = int(not_replying_str) if not_replying_str.isdigit() else 0
    faulty_links = int(faulty_links_str) if faulty_links_str.isdigit() else 0

    # Determine state
    sync_state = SYNC_STATUS_MAPPING.get(sync, "UNKNOWN")
    status = sync_state

    # Not replying > 0 -> CRIT (overrides sync state)
    if not_replying > 0:
        status = "CRIT"

    # Faulty links > 0 -> CRIT (overrides sync state unless already CRIT)
    if faulty_links > 0 and status != "CRIT":
        status = "CRIT"

    # Build summary message
    sync_name = SYNC_NAME_MAPPING.get(sync, "Unknown / Error")
    summary_parts = [
        "Sync Status: %s" % sync_name,
        "Member: %s, Active: %s, Links used: %s" % (number, active, eth_links),
        "Not replying: %d" % not_replying,
        "Faulty: %d" % faulty_links,
    ]
    msg = "; ".join(summary_parts)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": status,
            "metrics": {},
            "details": ""
        },
    }
