def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    version = params.get("version", "2c")

    # Discovery mode
    if params.get("_discover"):
        # Probe for 3PAR presence - check if the 3PAR SNMP MIB is available
        # by walking the hosts table OID
        res = ctx.run([
            "snmpwalk", "-v" + version, "-c", community,
            "-Oqn", "-m", "", host,
            ".1.3.6.1.4.1.235.195.17.1.4.1.1"
        ], mutates=False)
        if res.rc != 0 and res.rc != 127:
            # SNMP error or no response
            if res.rc == 127:
                return {"changed": False, "msg": "snmpwalk not found", "data": {"discovery": []}}
            return {"changed": False, "msg": "no 3PAR hosts accessible", "data": {"discovery": []}}

        # Parse the walk output - each line is "<OID> <value>"
        lines = res.stdout.splitlines()
        if not lines or not lines[0]:
            return {"changed": False, "msg": "no 3PAR hosts found", "data": {"discovery": []}}

        # Walk the hosts name column to get host names and their indices
        # OID .1.3.6.1.4.1.235.195.17.1.4.1.1 = 3parHostTable (hostName column)
        # Index is the part after .1.3.6.1.4.1.235.195.17.1.4.1.1.
        col_oid = ".1.3.6.1.4.1.235.195.17.1.4.1.1"
        hosts = []
        for line in lines:
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            value = parts[1]
            if not oid.startswith(col_oid + "."):
                continue
            index = oid[len(col_oid) + 1:]
            name = value.strip().strip('"')
            hosts.append({"item": name, "params": {}, "metrics": ["fc_paths", "iscsi_paths"]})

        return {
            "changed": False,
            "msg": "discovered %d hosts" % len(hosts),
            "data": {"discovery": hosts}
        }

    # Check mode
    item = params.get("item", "")

    # Verify 3PAR is accessible
    res = ctx.run([
        "snmpget", "-v" + version, "-c", community,
        "-Oqv", "-m", "", host,
        col_oid + "." + item  # Need to map item to index
    ], mutates=False)

    if res.rc != 0 or res.rc == 127:
        if res.rc == 127:
            return {"changed": False, "msg": "snmpget not found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        return {"changed": False, "msg": "3PAR host not accessible", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Get host data via SNMP table columns
    # We need to walk all columns of the hosts table and correlate by index
    # Columns: hostName(.1), hostId(.2), hostOs(.3), hostFcPaths(.4), hostIscsiPaths(.5)
    base_oid = ".1.3.6.1.4.1.235.195.17.1.4.1"

    # Walk each column
    walk_res = ctx.run([
        "snmpwalk", "-v" + version, "-c", community,
        "-Oqn", "-m", "", host,
        base_oid
    ], mutates=False)

    if walk_res.rc != 0 and walk_res.rc != 127:
        return {"changed": False, "msg": "failed to query 3PAR hosts", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse all table rows and build a map by index
    col_oids = {}
    for line in walk_res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        oid = parts[0]
        value = parts[1]
        # Find which column this OID corresponds to
        suffix = oid[len(base_oid) + 1:]
        col_parts = suffix.split(".", 1)
        if len(col_parts) < 2:
            continue
        col_num = col_parts[0]
        index = col_parts[1]
        if index not in col_oids:
            col_oids[index] = {}
        col_oids[index][col_num] = value.strip().strip('"')

    # Find the entry matching our item (host name)
    target = None
    for idx, cols in col_oids.items():
        if cols.get("1", "") == item:
            target = cols
            break

    if target == None:
        return {"changed": False, "msg": "no such host: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    host_id = target.get("2", "unknown")
    host_os = target.get("3", "")
    fc_paths = 0
    iscsi_paths = 0
    fc_val = target.get("4", "0")
    iscsi_val = target.get("5", "0")
    if fc_val.isdigit():
        fc_paths = int(fc_val)
    if iscsi_val.isdigit():
        iscsi_paths = int(iscsi_val)

    metrics = {"fc_paths": fc_paths, "iscsi_paths": iscsi_paths}
    details = "ID: %s" % host_id
    if host_os:
        details = details + "\nOS: %s" % host_os
    if fc_paths:
        details = details + "\nFC Paths: %d" % fc_paths
    elif iscsi_paths:
        details = details + "\niSCSI Paths: %d" % iscsi_paths

    msg = "ID: %s" % host_id
    if host_os:
        msg = msg + ", OS: %s" % host_os
    if fc_paths:
        msg = msg + ", FC Paths: %d" % fc_paths
    elif iscsi_paths:
        msg = msg + ", iSCSI Paths: %d" % iscsi_paths

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": "OK",
            "metrics": metrics,
            "details": details
        }
    }