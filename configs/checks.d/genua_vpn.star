def main(ctx, params):
    if params.get("_discover"):
        # Probe for the real thing: a Genua device via SNMP sysDescr.
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        sysdesc = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"],
            mutates=False,
        )
        if sysdesc.rc != 0:
            return {"changed": False, "msg": "no Genua device found",
                    "data": {"discovery": []}}
        sysdesc_val = sysdesc.stdout.strip().strip('"')
        is_genua = "genuscreen" in sysdesc_val or "genubox" in sysdesc_val or "genucrypt" in sysdesc_val
        if not is_genua:
            return {"changed": False, "msg": "no Genua device found",
                    "data": {"discovery": []}}

        # Walk the base OID .1.3.6.1.4.1.3717.2.1.3.1 for columns 1 (vpn_id) and 4 (vpn_state).
        col_oid = ".1.3.6.1.4.1.3717.2.1.3.1.1"
        walk = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, col_oid],
            mutates=False,
        )
        if walk.rc != 0:
            return {"changed": False, "msg": "no Genua device found",
                    "data": {"discovery": []}}

        items = []
        for line in walk.stdout.splitlines():
            sp = line.find(" ")
            if sp == -1:
                continue
            oid = line[:sp]
            val = line[sp + 1:].strip().strip('"')
            # index = oid suffix after col_oid + "."
            if not oid.startswith(col_oid + "."):
                continue
            index = oid[len(col_oid) + 1:]
            if index:
                items.append(index)

        discovery = []
        for idx in items:
            discovery.append({
                "item": idx,
                "params": {},
                "metrics": ["vpn_state"],
            })
        return {"changed": False, "msg": "discovered %d VPN connections" % len(discovery),
                "data": {"discovery": discovery}}

    # CHECK MODE — evaluate one VPN connection.
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base = ".1.3.6.1.4.1.3717.2.1.3.1"

    cols = {
        "1": ".1.3.6.1.4.1.3717.2.1.3.1.1",
        "2": ".1.3.6.1.4.1.3717.2.1.3.1.2",
        "3": ".1.3.6.1.4.1.3717.2.1.3.1.3",
        "4": ".1.3.6.1.4.1.3717.2.1.3.1.4",
        "5": ".1.3.6.1.4.1.3717.2.1.3.1.5",
        "6": ".1.3.6.1.4.1.3717.2.1.3.1.6",
    }

    values = {}
    # Column 1 (vpn_id) and 6 (vpn_state) are indexed by the item (table index).
    for col in ["1", "6"]:
        oid = cols[col] + "." + item
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
            mutates=False,
        )
        if res.rc != 0:
            return {"changed": False,
                    "msg": "no VPN connection found: %s" % item,
                    "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
        values[col] = res.stdout.strip().strip('"')

    vpn_state = values["6"]
    vpn_id = values["1"]

    # Gather remaining columns for the infotext (hostname opposite, ip opposite,
    # vpn private, vpn remote). Missing columns are tolerated via rc check.
    hostname_opposite = ""
    ip_opposite = ""
    vpn_private = ""
    vpn_remote = ""
    for col, holder in [("2", "hostname_opposite"), ("3", "ip_opposite"),
                        ("4", "vpn_private"), ("5", "vpn_remote")]:
        oid = cols[col] + "." + item
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
            mutates=False,
        )
        if res.rc == 0:
            v = res.stdout.strip().strip('"')
            if holder == "hostname_opposite":
                hostname_opposite = v
            elif holder == "ip_opposite":
                ip_opposite = v
            elif holder == "vpn_private":
                vpn_private = v
            elif holder == "vpn_remote":
                vpn_remote = v

    ip_info = " (%s)" % ip_opposite if ip_opposite else ""
    infotext = "Hostname: %s%s, VPN private: %s, VPN remote: %s" % (
        hostname_opposite, ip_info, vpn_private, vpn_remote)

    state_val = "OK" if vpn_state == "2" else "CRIT"
    summary = ("Connected, %s" % infotext) if vpn_state == "2" else ("Disconnected, %s" % infotext)

    return {"changed": False,
            "msg": summary,
            "data": {"state": state_val, "metrics": {"vpn_state": 1 if vpn_state == "2" else 0},
                     "details": ""}}