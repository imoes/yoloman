def main(ctx, params):
    # This check monitors Checkpoint firewall power supplies via SNMP.
    # The SNMP table is at .1.3.6.1.4.1.2620.1.6.7.9.1.1
    # Column 1 = index (power supply identifier), Column 2 = device status

    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base_oid = ".1.3.6.1.4.1.2620.1.6.7.9.1.1"

    # ---- DETECT: verify this is a Checkpoint firewall ----
    # Checkmk DETECT uses all_of:
    #   any_of( startswith(sysOID, ".1.3.6.1.4.1.2620"),
    #           matches(sysDescr, "[^ ]+ [^ ]+ [^ ]*cp( .*)?"),
    #           startswith(sysDescr, "IPSO "),
    #           matches(sysDescr, "Linux.*cpx.*") )
    #   any_of( startswith(.1.3.6.1.4.1.2620.1.1.21.0, "firewall"),
    #           matches(.1.3.6.1.4.1.2620.1.6.5.1.0, "Gaia") )

    def _snmpwalk(oid):
        return ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-Oqn",
            host, oid,
        ], mutates=False)

    def _snmpget(oid):
        return ctx.run([
            "snmpget", "-v2c", "-c", community, "-Oqv",
            host, oid,
        ], mutates=False)

    # Probe sysOID (.1.3.6.1.2.1.1.2.0) - should start with .1.3.6.1.4.1.2620
    sys_oid_res = _snmpget(".1.3.6.1.2.1.1.2.0")
    is_checkpoint = False
    if sys_oid_res.rc == 0:
        sys_oid_val = sys_oid_res.stdout.strip()
        if sys_oid_val.startswith(".1.3.6.1.4.1.2620"):
            is_checkpoint = True

    # Probe sysDescr (.1.3.6.1.2.1.1.1.0) - check patterns
    if not is_checkpoint:
        descr_res = _snmpget(".1.3.6.1.2.1.1.1.0")
        if descr_res.rc == 0:
            descr = descr_res.stdout.strip()
            # matches "[^ ]+ [^ ]+ [^ ]*cp( .*)?"
            parts = descr.split(" ")
            if len(parts) >= 3:
                third = parts[2]
                if third.startswith("cp"):
                    is_checkpoint = True
            # startswith "IPSO "
            if descr.startswith("IPSO "):
                is_checkpoint = True
            # matches "Linux.*cpx.*"
            if descr.startswith("Linux") and descr.find("cpx") >= 0:
                is_checkpoint = True

    # Probe firewall product OID (.1.3.6.1.4.1.2620.1.1.21.0) or Gaia (.1.3.6.1.4.1.2620.1.6.5.1.0)
    if not is_checkpoint:
        fw_res = _snmpget(".1.3.6.1.4.1.2620.1.1.21.0")
        if fw_res.rc == 0 and fw_res.stdout.strip().startswith("firewall"):
            is_checkpoint = True

    if not is_checkpoint:
        gw_res = _snmpget(".1.3.6.1.4.1.2620.1.6.5.1.0")
        if gw_res.rc == 0 and gw_res.stdout.strip().startswith("Gaia"):
            is_checkpoint = True

    # ---- DISCOVERY MODE ----
    if params.get("_discover"):
        if not is_checkpoint:
            return {"changed": False, "msg": "host is not a Checkpoint firewall", "data": {"discovery": []}}

        # Walk the power supply table columns
        idx_res = _snmpwalk(base_oid + ".1")  # column 1 = index
        if idx_res.rc != 0:
            return {"changed": False, "msg": "failed to walk power supply index, no Checkpoint power supply data", "data": {"discovery": []}}

        items = []
        for line in idx_res.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            line_oid = parts[0]
            line_val = parts[1]
            # Verify the OID is under our base column
            if not line_oid.startswith(base_oid + ".1."):
                continue
            # Index is the OID suffix after the column base
            index = line_oid[len(base_oid + ".1."):]
            if index == "" or index == "0":
                continue
            # Query the status for this index
            stat_res = _snmpget(base_oid + ".2." + index)
            if stat_res.rc == 0:
                status_val = stat_res.stdout.strip()
            else:
                status_val = "unknown"
            items.append({
                "item": index,
                "params": {},
                "metrics": [],
            })
        return {"changed": False, "msg": "discovered %d power supplies" % len(items), "data": {"discovery": items}}

    # ---- CHECK MODE ----
    item = params.get("item", "")
    if not is_checkpoint:
        return {"changed": False, "msg": "host is not a Checkpoint firewall, no Checkpoint power supply data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Walk to find the item and fetch its status
    idx_res = _snmpwalk(base_oid + ".1")
    if idx_res.rc != 0:
        return {"changed": False, "msg": "failed to walk power supply index, no Checkpoint power supply data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    found = False
    for line in idx_res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) < 2:
            continue
        line_oid = parts[0]
        if not line_oid.startswith(base_oid + ".1."):
            continue
        index = line_oid[len(base_oid + ".1."):]
        if index == item:
            found = True
            stat_res = _snmpget(base_oid + ".2." + index)
            if stat_res.rc != 0:
                break
            dev_status = stat_res.stdout.strip()
            break

    if not found:
        return {"changed": False, "msg": "power supply %s not found" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Grade using check_default_parameters
    # up=OK, ok=OK, present=CRIT, no_redundancy=WARN
    check_default_parameters = {
        "up": 0,
        "ok": 0,
        "present": 2,
        "no_redundancy": 1,
    }
    state_map = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}
    key = dev_status.lower().replace(" ", "_")
    cmk_state_num = check_default_parameters.get(key, 2)  # default CRIT
    state_str = state_map.get(cmk_state_num, "UNKNOWN")

    return {"changed": False, "msg": dev_status, "data": {"state": state_str, "metrics": {}, "details": ""}}