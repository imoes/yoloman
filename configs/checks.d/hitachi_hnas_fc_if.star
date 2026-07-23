def _parse_line(line):
    # Parse a single SNMP table row into interface data
    # line is a list of strings from the SNMP walk (base OIDs + index)
    # Expected fields: clusterNode(0), idx(1), status(2), linkSpeed(3),
    #                  inRate(4), outRate(5), signalLoss(6..12), disc(13)
    if len(line) < 14:
        return None
    cluster_node = line[0]
    idx = line[1]
    status = line[2]
    link_speed = line[3]
    in_rate = line[4]
    out_rate = line[5]
    signal_loss = line[6]
    bad_rx_char = line[7]
    loss_sync = line[8]
    link_fail = line[9]
    rx_eof = line[10]
    bad_crc = line[11]
    proto_err = line[12]
    disc_frame = line[13]

    # Compute oper_status: "1" means up, "2" means down (from SNMP truth value)
    oper_status = "1" if status == "1" else "2"

    # Compute error counters: sum of several error types if all present
    err_fields = [signal_loss, bad_rx_char, loss_sync, link_fail, rx_eof, bad_crc, proto_err]
    has_all_errors = True
    for f in err_fields:
        if f == "":
            has_all_errors = False
            break
        if not f.isdigit():
            has_all_errors = False
            break

    in_err = None
    if has_all_errors and len(err_fields) == 7:
        in_err = 0
        for f in err_fields:
            in_err = in_err + int(f)

    return {
        "index": "%s%s" % (cluster_node, idx),
        "descr": cluster_node + "." + idx,
        "alias": cluster_node + "." + idx,
        "speed": int(link_speed) * 1000000000 if link_speed.isdigit() else 0,
        "oper_status": oper_status,
        "in_octets": int(in_rate) if in_rate.isdigit() else 0,
        "in_disc": int(disc_frame) if disc_frame.isdigit() else None,
        "in_err": in_err,
        "out_octets": int(out_rate) if out_rate.isdigit() else 0,
    }

def _snmp_walk_table(ctx, host, community, base_oid):
    # Walk base OID and parse rows into list of lists of strings
    res = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On", host,
        base_oid
    ], mutates=False)

    if res.rc != 0:
        return None

    out = []
    for line in res.stdout.splitlines():
        line = line.strip()
        if line == "":
            continue
        # Format: ".1.3.6.1.4.1.11096.6.1.1.1.3.6.25.1.<index> = STRING: <value>"
        # Extract value part after " = "
        idx = line.find(" = ")
        if idx == -1:
            continue
        value_part = line[idx + 3:].strip()
        # Strip quotes from STRING type (common in snmpwalk output)
        if value_part.startswith("\"") and value_part.endswith("\""):
            value_part = value_part[1:-1]
        out.append(value_part.split())

    return out

def _format_speed(speed):
    # speed in bps
    if speed >= 1000000000:
        return "%f Gbit/s" % (speed / 1000000000.0)
    elif speed >= 1000000:
        return "%f Mbit/s" % (speed / 1000000.0)
    else:
        return "%f bit/s" % speed

def main(ctx, params):
    # === Discovery mode ===
    if params.get("_discover"):
        host = params.get("host", "localhost")
        community = params.get("community", "public")
        base_oid = ".1.3.6.1.4.1.11096.6.1.1.1.3.6.25.1"

        rows = _snmp_walk_table(ctx, host, community, base_oid)
        if rows == None:
            return {
                "changed": False,
                "msg": "SNMP walk failed",
                "data": {"discovery": []}
            }

        items = []
        for row in rows:
            parsed = _parse_line(row)
            if parsed != None:
                # Use "Interface FC %s" format for item name: clusterNode.InterfaceIndex
                item_name = parsed["descr"]
                items.append({
                    "item": item_name,
                    "params": {
                        "speed": parsed["speed"],
                        "state": parsed["oper_status"]
                    },
                    "metrics": ["in", "out", "in_octets", "out_octets", "in_errors", "out_errors"]
                })

        return {
            "changed": False,
            "msg": "discovered %d FC interfaces" % len(items),
            "data": {"discovery": items}
        }

    # === Check mode ===
    item = params.get("item", "")
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    base_oid = ".1.3.6.1.4.1.11096.6.1.1.1.3.6.25.1"

    # Discover current state of all FC interfaces first
    rows = _snmp_walk_table(ctx, host, community, base_oid)
    if rows == None:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Find the specific interface by descr (which matches item name)
    target = None
    for row in rows:
        parsed = _parse_line(row)
        if parsed == None:
            continue
        if parsed["descr"] == item:
            target = parsed
            break

    if target == None:
        return {
            "changed": False,
            "msg": "interface not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Extract metrics and apply if64 generic_check_if64 logic (simplified)
    in_octets = target["in_octets"]
    out_octets = target["out_octets"]
    in_disc = target["in_disc"]
    in_err = target["in_err"]
    out_disc = None  # not reported in source
    out_err = None  # not reported in source

    # Map oper_status to Checkmk states
    # "1" = up -> OK; "2" = down -> CRIT (per if64 defaults)
    state = "OK"
    if target["oper_status"] == "2":
        state = "CRIT"

    # Compute per-interface stats (if64 logic uses rates)
    # We report raw counters; checkmk's if64 will compute rates
    metrics = {
        "in_octets": in_octets,
        "out_octets": out_octets
    }

    # Add error and discard counters if available
    if in_disc != None:
        metrics["in_discarded"] = in_disc
    if in_err != None:
        metrics["in_errors"] = in_err
    if out_disc != None:
        metrics["out_discarded"] = out_disc
    if out_err != None:
        metrics["out_errors"] = out_err

    # Build human-readable summary
    summary = "%s: %s" % (item, "up" if state == "OK" else "down")
    if target["speed"] > 0:
        summary = summary + ", " + _format_speed(target["speed"])

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }