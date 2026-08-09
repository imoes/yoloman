def _isdigit(s):
    return s != None and s != "" and s.lstrip("-").isdigit()

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # ----- Discovery mode -----
    if params.get("_discover"):
        # Probe for Brocade device — sysDescr OID .1.3.6.1.2.1.1.1.0
        probe = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Ov", host, ".1.3.6.1.2.1.1.1.0"],
            mutates=False,
        )
        if probe.rc == 127 or probe.rc == 1 or probe.rc == 2:
            return {"changed": False, "msg": "no SNMP/Brocade device found",
                    "data": {"discovery": []}}
        if probe.stdout.find("1.3.6.1.4.1.1588") == -1:
            return {"changed": False, "msg": "not a Brocade device",
                    "data": {"discovery": []}}

        # Walk the SFP stats table (swSfpStatEntry = .1.3.6.1.4.1.1588.2.1.1.1.28.1.1)
        # Column for temperature is .1 under that base.
        stats_walk = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host,
             ".1.3.6.1.4.1.1588.2.1.1.1.28.1.1.1"],
            mutates=False,
        )
        if stats_walk.rc != 0 or not stats_walk.stdout.strip():
            return {"changed": False, "msg": "no SFP stats found",
                    "data": {"discovery": []}}

        sfp_indices = []
        stats_base_len = len(".1.3.6.1.4.1.1588.2.1.1.1.28.1.1.1")
        for line in stats_walk.stdout.splitlines():
            parts = line.strip().split(" ", 1)
            if len(parts) < 2:
                continue
            oid = parts[0]
            suffix = oid[stats_base_len:]
            if suffix.startswith("."):
                idx = suffix[1:]
                if idx:
                    sfp_indices.append(idx)

        if not sfp_indices:
            return {"changed": False, "msg": "no SFP stats found",
                    "data": {"discovery": []}}

        # Walk the fcport info table (.1.3.6.1.4.1.1588.2.1.1.1.6.2.1)
        # Columns: 1=swFCPortIndex, 3=swFCPortPhyState, 4=swFCPortOpStatus,
        #          5=swFCPortAdmStatus, 36=swFCPortName
        info_walk = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host,
             ".1.3.6.1.4.1.1588.2.1.1.1.6.2.1"],
            mutates=False,
        )
        info = {}
        info_base_len = len(".1.3.6.1.4.1.1588.2.1.1.1.6.2.1")
        if info_walk.rc == 0 and info_walk.stdout.strip():
            for line in info_walk.stdout.splitlines():
                parts = line.strip().split(" ", 1)
                if len(parts) < 2:
                    continue
                oid = parts[0]
                val = parts[1]
                suffix = oid[info_base_len:]
                bits = suffix.split(".")
                if len(bits) < 3:
                    continue
                col = bits[1]
                pindex = bits[2]
                if pindex not in info:
                    info[pindex] = {}
                info[pindex][col] = val

        # Walk the ISL table (.1.3.6.1.4.1.1588.2.1.1.1.2.9.1, col 2 = swNbMyPort)
        isl_walk = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host,
             ".1.3.6.1.4.1.1588.2.1.1.1.2.9.1.2"],
            mutates=False,
        )
        isl_ports = []
        isl_base_len = len(".1.3.6.1.4.1.1588.2.1.1.1.2.9.1.2")
        if isl_walk.rc == 0 and isl_walk.stdout.strip():
            for line in isl_walk.stdout.splitlines():
                parts = line.strip().split(" ", 1)
                if len(parts) < 2:
                    continue
                oid = parts[0]
                suffix = oid[isl_base_len:]
                if suffix.startswith("."):
                    isl_ports.append(suffix[1:])

        admstates = [1, 3, 4]
        phystates = [3, 4, 5, 6, 7, 8, 9, 10]
        opstates = [1, 2, 3, 4]

        number_of_ports = len(info)
        width = len(str(number_of_ports)) if number_of_ports > 0 else 1

        discovery = []
        for idx in sfp_indices:
            pinfo = info.get(idx)
            if pinfo == None:
                continue

            adm_raw = pinfo.get("5")
            admstate = int(adm_raw) if _isdigit(adm_raw) else 0
            phy_raw = pinfo.get("3")
            phystate = int(phy_raw) if _isdigit(phy_raw) else 0
            op_raw = pinfo.get("4")
            opstate = int(op_raw) if _isdigit(op_raw) else 0

            if admstate not in admstates:
                continue
            if phystate not in phystates:
                continue
            if opstate not in opstates:
                continue

            is_isl = idx in isl_ports

            portname_raw = pinfo.get("36")
            portname = portname_raw if portname_raw != None else ""

            itemname = ("%0" + str(width) + "d") % (int(idx) - 1)
            if is_isl:
                itemname += " ISL"
            pname_stripped = portname.strip()
            if pname_stripped:
                itemname += " " + pname_stripped

            discovery.append({
                "item": itemname,
                "params": {"warn": 55.0, "crit": 60.0},
                "metrics": ["temperature"],
            })

        return {"changed": False, "msg": "discovered %d SFP ports" % len(discovery),
                "data": {"discovery": discovery}}

    # ----- Check mode -----
    item = params.get("item", "")
    if item == "":
        return {"changed": False, "msg": "no item specified",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse the port index from the item (first whitespace-delimited token, zero-based)
    first_tok = item.split(None, 1)[0]
    if not _isdigit(first_tok):
        return {"changed": False, "msg": "invalid item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    port_index = int(first_tok) + 1

    # Query the temperature for this port: swSfpTemperature for OID index = port_index
    # swSfpTemperature column is .1 under swSfpStatEntry base
    temp_oid = ".1.3.6.1.4.1.1588.2.1.1.1.28.1.1.1." + str(port_index)
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, temp_oid],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout.strip():
        return {"changed": False, "msg": "SFP not found for item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Value may come as "INTEGER: 42" or bare; strip type tag if present
    raw_val = res.stdout.strip()
    if raw_val.find(": ") != -1:
        raw_val = raw_val.split(": ", 1)[1]
    # Strip surrounding quotes if any
    if raw_val.startswith('"') and raw_val.endswith('"'):
        raw_val = raw_val[1:-1]
    if not _isdigit(raw_val):
        return {"changed": False, "msg": "invalid temperature value for item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    temp = float(raw_val)

    warn = params.get("warn", 55.0)
    crit = params.get("crit", 60.0)

    state = "CRIT" if temp >= crit else ("WARN" if temp >= warn else "OK")

    return {"changed": False,
            "msg": "%s: %f C" % (item, temp),
            "data": {"state": state, "metrics": {"temperature": temp}, "details": ""}}