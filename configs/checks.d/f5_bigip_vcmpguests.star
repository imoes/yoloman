def main(ctx, params):
    # Discovery mode: produce one service for this host
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service",
            "data": {"discovery": [{"item": "", "params": {}, "metrics": []}]},
        }

    # Check mode: fetch vCMP guests via SNMP
    # Base OID: .1.3.6.1.4.1.3375.2.1.13.4.2.1
    # OID 1: sysVcmpStatVcmpName (guest name)
    # OID 17: sysVcmpStatPrompt (status)
    res = ctx.run([
        "snmpwalk", "-On", "-v2c", "-c", "public", "localhost",
        ".1.3.6.1.4.1.3375.2.1.13.4.2.1.1",
        ".1.3.6.1.4.1.3375.2.1.13.4.2.1.17"
    ], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP query failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Parse the flat list of OIDs and values
    lines = res.stdout.splitlines()
    # Reorganize into guest-name -> status mapping
    guest_status = {}
    names = []
    statuses = []
    for line in lines:
        parts = line.strip().split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_path, value = parts
        value = value.strip()
        if oid_path.endswith(".1"):
            # guest name
            names.append(value)
        elif oid_path.endswith(".17"):
            # status
            statuses.append(value)

    for i in range(min(len(names), len(statuses))):
        guest = names[i]
        status = statuses[i].lower()
        if not status.startswith("\""):
            # Strip quotes if present
            if status.startswith('"') and status.endswith('"'):
                status = status[1:-1]
            status = status.lower()
        guest_status[guest] = status

    # Report per-guest state
    messages = []
    for guest, status in sorted(guest_status.items()):
        messages.append("Guest [%s] is %s" % (guest, status))

    if not guest_status:
        return {
            "changed": False,
            "msg": "No vCMP guests found",
            "data": {"state": "OK", "metrics": {}, "details": ""},
        }

    return {
        "changed": False,
        "msg": "; ".join(messages),
        "data": {"state": "OK", "metrics": {}, "details": ""},
    }
