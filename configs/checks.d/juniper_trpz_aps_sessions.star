def main(ctx, params):
    if params.get("_discover"):
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", community,
            "-On",
            host,
            ".1.3.6.1.4.1.14525.4.5.1.1.2.1"
        ], mutates=False)
        
        items = []
        for line in res.stdout.splitlines():
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_end = parts[0].strip()
            value_part = parts[1].strip()
            if ":" in value_part:
                ap_name = value_part.rsplit(":", 1)[-1].strip().strip('"')
                if ap_name:
                    items.append({
                        "item": ap_name,
                        "params": {},
                        "metrics": ["status", "if_out_unicast", "if_out_unicast_octets", "if_out_non_unicast",
                                    "if_out_non_unicast_octets", "if_in_pkts", "if_in_octets", "wlan_physical_errors",
                                    "wlan_resets", "wlan_retries", "total_sessions", "noise_floor"]
                    })
        
        return {
            "changed": False,
            "msg": "discovered %d access points" % len(items),
            "data": {"discovery": items}
        }

    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    res_ap = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On",
        host,
        ".1.3.6.1.4.1.14525.4.5.1.1.2.1"
    ], mutates=False)
    
    ap_status = None
    ap_oid = None
    
    for line in res_ap.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_end = parts[0].strip()
        value_part = parts[1].strip()
        if ":" in value_part:
            ap_name = value_part.rsplit(":", 1)[-1].strip().strip('"')
            if ap_name == item:
                status_str = value_part.split(":")[0].strip().strip('"')
                ap_status = status_str
                ap_oid = oid_end
                break
    
    if ap_status == None:
        return {
            "changed": False,
            "msg": "Access point %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    ap_states = {
        "1": ("OK", "cleared"),
        "2": ("WARN", "init"),
        "3": ("CRIT", "boot started"),
        "4": ("CRIT", "image downloaded"),
        "5": ("CRIT", "connect failed"),
        "6": ("WARN", "configuring"),
        "7": ("OK", "operational"),
        "10": ("OK", "redundant"),
        "20": ("CRIT", "conn outage"),
    }
    
    state_tuple = ap_states.get(ap_status, ("UNKNOWN", "unknown"))
    state_name = state_tuple[0]
    status_desc = state_tuple[1]
    
    res_radio = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", community,
        "-On",
        host,
        ".1.3.6.1.4.1.14525.4.5.1.1.10.1"
    ], mutates=False)
    
    radio_data = {}
    
    for line in res_radio.stdout.splitlines():
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_str = parts[0].strip()
        value_str = parts[1].strip()
        oid_parts = oid_str.rsplit(".", 1)
        if len(oid_parts) != 2:
            continue
        base_oid, radio_num = oid_parts
        if base_oid != ap_oid:
            continue
        val = int(value_str) if value_str.isdigit() else 0
        full_oid = oid_str
        field_num = int(full_oid.split(".")[-2]) if len(full_oid.split(".")) >= 2 else 0
        field_idx = field_num - 3
        if (0 <= field_idx) and (field_idx < 11):
            radio_data.setdefault(radio_num, [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
            radio_data[radio_num][field_idx] = val
    
    radio_summaries = []
    metrics = {}
    total_sessions = 0
    noise_floors = []
    
    for radio_num in sorted(radio_data.keys(), key=lambda x: int(x)):
        counters = radio_data[radio_num]
        txUniPkt, txUniOct, txMultiPkt, txMultiOct, rxPkt, rxOctet, phyErr, resetCount, rxRetriesCount, userSessions, noiseFloor = counters
        
        in_octets = float(rxOctet)
        out_unicast_octets = float(txUniOct)
        out_non_unicast_octets = float(txMultiOct)
        
        in_bits = in_octets * 8
        out_bits = (out_unicast_octets + out_non_unicast_octets) * 8
        
        radio_summaries.append("Radio %s: Input: %s, Output: %s, Errors: %d, Resets: %d, Retries: %d, Sessions: %d, Noise: %d dBm" % (
            radio_num,
            "%f Bit/s" % in_bits,
            "%f Bit/s" % out_bits,
            int(phyErr),
            int(resetCount),
            int(rxRetriesCount),
            int(userSessions),
            int(noiseFloor)
        ))
        
        total_sessions += int(userSessions)
        if noiseFloor > 0:
            noise_floors.append(int(noiseFloor))
        
        metrics["wlan_radio_%s_if_out_unicast" % radio_num] = float(txUniPkt)
        metrics["wlan_radio_%s_if_out_unicast_octets" % radio_num] = out_unicast_octets
        metrics["wlan_radio_%s_if_out_non_unicast" % radio_num] = float(txMultiPkt)
        metrics["wlan_radio_%s_if_out_non_unicast_octets" % radio_num] = out_non_unicast_octets
        metrics["wlan_radio_%s_if_in_pkts" % radio_num] = float(rxPkt)
        metrics["wlan_radio_%s_if_in_octets" % radio_num] = in_octets
        metrics["wlan_radio_%s_wlan_physical_errors" % radio_num] = float(phyErr)
        metrics["wlan_radio_%s_wlan_resets" % radio_num] = float(resetCount)
        metrics["wlan_radio_%s_wlan_retries" % radio_num] = float(rxRetriesCount)
        metrics["wlan_radio_%s_total_sessions" % radio_num] = float(userSessions)
        metrics["wlan_radio_%s_noise_floor" % radio_num] = float(noiseFloor)
    
    metrics["total_sessions"] = float(total_sessions)
    if noise_floors:
        metrics["noise_floor"] = float(max(noise_floors))
    
    msg = "Status: %s" % status_desc
    if radio_summaries:
        msg += "; " + "; ".join(radio_summaries)
    
    state = "OK"
    if state_name == "WARN":
        state = "WARN"
    elif state_name == "CRIT":
        state = "CRIT"
    elif state_name == "UNKNOWN":
        state = "UNKNOWN"
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }