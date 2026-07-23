def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        walk_if = ctx.run([
            "snmpwalk", "-v2c", "-c", community, "-On", host,
            "1.3.6.1.2.1.2.2.1.2"
        ], mutates=False)
        if walk_if.rc != 0 or not walk_if.stdout.strip():
            return {"changed": False, "msg": "no interfaces found",
                    "data": {"discovery": []}}

        ifaces = []
        for line in walk_if.stdout.splitlines():
            parts = line.strip().split()
            if len(parts) < 2:
                continue
            oid = parts[0]
            if '.' not in oid:
                continue
            idx = oid.rsplit('.', 1)[-1]
            if not idx.isdigit():
                continue
            name_part = " ".join(parts[2:]) if len(parts) > 2 else ""
            name = name_part.strip('"').strip("'").strip()
            if name and int(idx) > 0:
                ifaces.append({"index": idx, "name": name})

        if not ifaces:
            return {"changed": False, "msg": "no interfaces found",
                    "data": {"discovery": []}}

        out = []
        for iface in ifaces:
            out.append({
                "item": iface["name"],
                "params": {"admin_states": ["up"], "lower_states": ["down"]},
                "metrics": ["in_octets", "out_octets", "in_errors", "out_errors",
                            "in_discards", "out_discards", "in_unicast", "in_broadcast",
                            "in_multicast", "out_unicast", "out_broadcast", "out_multicast",
                            "in_octets_rate", "out_octets_rate", "in_utilization",
                            "out_utilization"]
            })
        return {"changed": False, "msg": "discovered %d interfaces" % len(ifaces),
                "data": {"discovery": out}}

    # Check mode
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")

    oids = {
        "ifDescr": "1.3.6.1.2.1.2.2.1.2",
        "ifHCInOctets": "1.3.6.1.2.1.31.1.1.1.6",
        "ifHCOutOctets": "1.3.6.1.2.1.31.1.1.1.10",
        "ifInErrors": "1.3.6.1.2.1.2.2.1.14",
        "ifOutErrors": "1.3.6.1.2.1.2.2.1.20",
        "ifHCInUcastPkts": "1.3.6.1.2.1.31.1.1.1.7",
        "ifHCOutUcastPkts": "1.3.6.1.2.1.31.1.1.1.11",
        "ifHCInMulticastPkts": "1.3.6.1.2.1.31.1.1.1.8",
        "ifHCOutMulticastPkts": "1.3.6.1.2.1.31.1.1.1.12",
        "ifHCInBroadcastPkts": "1.3.6.1.2.1.31.1.1.1.9",
        "ifHCOutBroadcastPkts": "1.3.6.1.2.1.31.1.1.1.13",
        "ifInDiscards": "1.3.6.1.2.1.2.2.1.13",
        "ifOutDiscards": "1.3.6.1.2.1.2.2.1.19",
        "ifAdminStatus": "1.3.6.1.2.1.2.2.1.7",
        "ifOperStatus": "1.3.6.1.2.1.2.2.1.8",
        "ifSpeed": "1.3.6.1.2.1.2.2.1.5",
        "ifAlias": "1.3.6.1.2.1.31.1.1.1.18",
        "ifLastChange": "1.3.6.1.2.1.2.2.1.9"
    }

    walk_if = ctx.run([
        "snmpwalk", "-v2c", "-c", community, "-On", host, oids["ifDescr"]
    ], mutates=False)
    if walk_if.rc != 0 or not walk_if.stdout.strip():
        return {"changed": False, "msg": "failed to fetch interface list",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    target_idx = None
    for line in walk_if.stdout.splitlines():
        parts = line.strip().split()
        if len(parts) < 2:
            continue
        oid = parts[0]
        if '.' not in oid:
            continue
        idx = oid.rsplit('.', 1)[-1]
        name_part = " ".join(parts[2:]) if len(parts) > 2 else ""
        name = name_part.strip('"').strip("'").strip()
        if name == item:
            target_idx = idx
            break

    if target_idx == None:
        return {"changed": False, "msg": "interface %s not found" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    def get_oid_val(base_oid):
        oid_full = base_oid + "." + target_idx
        res = ctx.run([
            "snmpget", "-v2c", "-c", community, "-On", host, oid_full
        ], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            return None
        out = res.stdout.strip()
        idx = out.find(": ")
        if idx == -1:
            return None
        val = out[idx + 2:].strip()
        return val

    ifDescr = get_oid_val(oids["ifDescr"])
    ifHCInOctets = get_oid_val(oids["ifHCInOctets"])
    ifHCOutOctets = get_oid_val(oids["ifHCOutOctets"])
    ifInErrors = get_oid_val(oids["ifInErrors"])
    ifOutErrors = get_oid_val(oids["ifOutErrors"])
    ifHCInUcastPkts = get_oid_val(oids["ifHCInUcastPkts"])
    ifHCOutUcastPkts = get_oid_val(oids["ifHCOutUcastPkts"])
    ifHCInMulticastPkts = get_oid_val(oids["ifHCInMulticastPkts"])
    ifHCOutMulticastPkts = get_oid_val(oids["ifHCOutMulticastPkts"])
    ifHCInBroadcastPkts = get_oid_val(oids["ifHCInBroadcastPkts"])
    ifHCOutBroadcastPkts = get_oid_val(oids["ifHCOutBroadcastPkts"])
    ifInDiscards = get_oid_val(oids["ifInDiscards"])
    ifOutDiscards = get_oid_val(oids["ifOutDiscards"])
    ifAdminStatus = get_oid_val(oids["ifAdminStatus"])
    ifOperStatus = get_oid_val(oids["ifOperStatus"])
    ifSpeed = get_oid_val(oids["ifSpeed"])
    ifAlias = get_oid_val(oids["ifAlias"])

    def safeint(s):
        if s == None:
            return 0
        if s.isdigit():
            return int(s)
        return 0

    in_octets = safeint(ifHCInOctets)
    out_octets = safeint(ifHCOutOctets)
    in_errors = safeint(ifInErrors)
    out_errors = safeint(ifOutErrors)
    in_discards = safeint(ifInDiscards)
    out_discards = safeint(ifOutDiscards)
    in_unicast = safeint(ifHCInUcastPkts)
    out_unicast = safeint(ifHCOutUcastPkts)
    in_multicast = safeint(ifHCInMulticastPkts)
    out_multicast = safeint(ifHCOutMulticastPkts)
    in_broadcast = safeint(ifHCInBroadcastPkts)
    out_broadcast = safeint(ifHCOutBroadcastPkts)

    admin_state = "up" if ifAdminStatus == "1" else ("down" if ifAdminStatus == "2" else "testing")
    oper_state = "up" if ifOperStatus == "1" else ("down" if ifOperStatus == "2" else
                   ("testing" if ifOperStatus == "3" else "unknown" if ifOperStatus == "4" else
                    "dormant" if ifOperStatus == "5" else "notPresent" if ifOperStatus == "6" else
                    "lowerLayerDown"))

    speed = safeint(ifSpeed) if safeint(ifSpeed) > 0 else 10000000
    in_rate = in_octets * 8.0 / 300.0 if in_octets > 0 else 0.0
    out_rate = out_octets * 8.0 / 300.0 if out_octets > 0 else 0.0

    in_util = (in_rate / (speed / 100.0)) if speed > 0 else 0.0
    out_util = (out_rate / (speed / 100.0)) if speed > 0 else 0.0

    if admin_state == "down":
        state = "CRIT"
        msg = "admin down"
    elif oper_state == "down":
        state = "WARN"
        msg = "link down"
    else:
        state = "OK"
        msg = "up"

    details = ""
    if ifAlias != None and ifAlias != "":
        details = "alias: %s" % ifAlias

    metrics = {
        "in_octets": in_octets,
        "out_octets": out_octets,
        "in_errors": in_errors,
        "out_errors": out_errors,
        "in_discards": in_discards,
        "out_discards": out_discards,
        "in_unicast": in_unicast,
        "out_unicast": out_unicast,
        "in_multicast": in_multicast,
        "out_multicast": out_multicast,
        "in_broadcast": in_broadcast,
        "out_broadcast": out_broadcast,
        "in_octets_rate": in_rate,
        "out_octets_rate": out_rate,
        "in_utilization": in_util,
        "out_utilization": out_util,
    }

    summary = "%s: %s (%s), %d bytes in, %d bytes out" % (item, msg, oper_state, in_octets, out_octets)
    return {"changed": False,
            "msg": summary,
            "data": {"state": state, "metrics": metrics, "details": details}}