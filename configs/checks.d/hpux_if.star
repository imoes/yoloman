def hpux_parse_speed_safe(speed_str):
    parts = speed_str.split()
    if len(parts) < 2:
        return 0.0
    mult = 1000 * 1000 * 1000 if parts[1] == "Gbps" else 1000 * 1000
    val_str = parts[0]
    if val_str.isdigit():
        return int(val_str) * mult
    if val_str.find(".") >= 0:
        parts_dot = val_str.split(".")
        if len(parts_dot) == 2:
            if parts_dot[0].isdigit() and parts_dot[1].isdigit():
                return 0.0
    return 0.0

def hpux_parse_operstatus(txt):
    return "1" if txt.lower() == "up" else "2"

def parse_hpux_if(lines):
    nics = []
    iface = None
    for line in lines:
        if not line or line.find("=") < 0:
            continue
        if line.find("***") >= 0:
            if iface != None:
                iface["attributes"]["finalized"] = True
            iface = {
                "attributes": {
                    "index": "0",
                    "descr": "0",
                    "alias": "0",
                    "type": "6",
                    "speed": 0.0,
                    "oper_status": "2",
                    "phys_address": "",
                },
                "counters": {
                    "in_octets": 0,
                    "in_ucast": 0,
                    "in_mcast": 0,
                    "in_bcast": 0,
                    "in_disc": 0,
                    "in_err": 0,
                    "out_octets": 0,
                    "out_ucast": 0,
                    "out_mcast": 0,
                    "out_bcast": 0,
                    "out_disc": 0,
                    "out_err": 0,
                },
                "timestamp": 0,
            }
            nics.append(iface)
            continue
        eq_idx = line.find("=")
        left = line[:eq_idx].strip()
        right = line[eq_idx+1:].strip()
        if left == "PPA Number":
            iface["attributes"]["index"] = right
        elif left == "Interface Name":
            iface["attributes"]["descr"] = right
            iface["attributes"]["alias"] = right
        elif left == "Speed":
            iface["attributes"]["speed"] = hpux_parse_speed_safe(right)
        elif left == "Operation Status":
            iface["attributes"]["oper_status"] = hpux_parse_operstatus(right)
        elif left == "Station Address":
            h = right[2:] if len(right) > 2 else ""
            addr_parts = []
            ok = True
            i = 0
            while i < len(h):
                if i+1 >= len(h):
                    ok = False
                    break
                byte_str = h[i:i+2]
                if len(byte_str) == 2:
                    all_hex = True
                    for c in byte_str:
                        if not ((c >= "0" and c <= "9") or (c >= "a" and c <= "f") or (c >= "A" and c <= "F")):
                            all_hex = False
                            break
                    if all_hex:
                        byte_val = int(byte_str, 16)
                        addr_parts.append(chr(byte_val))
                    else:
                        ok = False
                        break
                else:
                    ok = False
                    break
                i += 2
            iface["attributes"]["phys_address"] = "".join(addr_parts) if ok else ""
        else:
            field_map = {
                "Inbound Octets": "in_octets",
                "Inbound Unicast Packets": "in_ucast",
                "Inbound Multicast Packets": "in_mcast",
                "Inbound Broadcast Packets": "in_bcast",
                "Inbound Discards": "in_disc",
                "Inbound Errors": "in_err",
                "Outbound Octets": "out_octets",
                "Outbound Unicast Packets": "out_ucast",
                "Outbound Multicast Packets": "out_mcast",
                "Outbound Broadcast Packets": "out_bcast",
                "Outbound Discards": "out_disc",
                "Outbound Errors": "out_err",
            }
            if left in field_map:
                field_name = field_map[left]
                if right.isdigit():
                    iface["counters"][field_name] = int(right)
                else:
                    iface["counters"][field_name] = 0
    if iface != None:
        iface["attributes"]["finalized"] = True
    return nics

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["/usr/contrib/bin/mxinfo", "interface"], mutates=False)
        lines = res.stdout.splitlines() if res.stdout else []
        nics = parse_hpux_if(lines)
        items = []
        for nic in nics:
            item = nic["attributes"]["descr"]
            params_for_item = {
                "speed": nic["attributes"]["speed"],
                "status": nic["attributes"]["oper_status"],
                "in_octets": nic["counters"]["in_octets"],
                "in_ucast": nic["counters"]["in_ucast"],
                "in_mcast": nic["counters"]["in_mcast"],
                "in_bcast": nic["counters"]["in_bcast"],
                "in_disc": nic["counters"]["in_disc"],
                "in_err": nic["counters"]["in_err"],
                "out_octets": nic["counters"]["out_octets"],
                "out_ucast": nic["counters"]["out_ucast"],
                "out_mcast": nic["counters"]["out_mcast"],
                "out_bcast": nic["counters"]["out_bcast"],
                "out_disc": nic["counters"]["out_disc"],
                "out_err": nic["counters"]["out_err"],
            }
            metrics = [
                "in_octets", "in_ucast", "in_mcast", "in_bcast", "in_disc", "in_err",
                "out_octets", "out_ucast", "out_mcast", "out_bcast", "out_disc", "out_err"
            ]
            items.append({
                "item": item,
                "params": params_for_item,
                "metrics": metrics,
            })
        return {
            "changed": False,
            "msg": "discovered %d interfaces" % len(nics),
            "data": {"discovery": items},
        }

    item = params.get("item", "")
    res = ctx.run(["/usr/contrib/bin/mxinfo", "interface"], mutates=False)
    lines = res.stdout.splitlines() if res.stdout else []
    nics = parse_hpux_if(lines)
    
    nic = None
    for n in nics:
        if n["attributes"]["descr"] == item:
            nic = n
            break
    
    if nic == None:
        return {
            "changed": False,
            "msg": "interface not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    in_octets = nic["counters"]["in_octets"]
    out_octets = nic["counters"]["out_octets"]
    in_ucast = nic["counters"]["in_ucast"]
    out_ucast = nic["counters"]["out_ucast"]
    in_mcast = nic["counters"]["in_mcast"]
    out_mcast = nic["counters"]["out_mcast"]
    in_bcast = nic["counters"]["in_bcast"]
    out_bcast = nic["counters"]["out_bcast"]
    in_disc = nic["counters"]["in_disc"]
    out_disc = nic["counters"]["out_disc"]
    in_err = nic["counters"]["in_err"]
    out_err = nic["counters"]["out_err"]
    speed = nic["attributes"]["speed"]
    oper_status = nic["attributes"]["oper_status"]
    
    speed_mbps = int(speed / 1000 / 1000) if speed > 0 else 0
    
    in_util = 0.0
    out_util = 0.0
    
    state = "OK"
    details = []
    
    if oper_status == "1":
        details.append("status: up")
    elif oper_status == "2":
        state = "CRIT"
        details.append("status: down")
    else:
        state = "UNKNOWN"
        details.append("status: unknown")
    
    if in_err > 0 or out_err > 0:
        state = "CRIT"
        details.append("errors in: %d, out: %d" % (in_err, out_err))
    
    if in_disc > 0 or out_disc > 0:
        if state == "OK":
            state = "WARN"
        details.append("discards in: %d, out: %d" % (in_disc, out_disc))
    
    warn_util = params.get("warn_util", 70.0)
    crit_util = params.get("crit_util", 90.0)
    
    if in_util >= crit_util:
        state = "CRIT"
        details.append("in_util: %f%%" % in_util)
    elif in_util >= warn_util:
        if state == "OK":
            state = "WARN"
        details.append("in_util: %f%%" % in_util)
    
    if out_util >= crit_util:
        state = "CRIT"
        details.append("out_util: %f%%" % out_util)
    elif out_util >= warn_util:
        if state == "OK":
            state = "WARN"
        details.append("out_util: %f%%" % out_util)
    
    metrics = {
        "in_octets": in_octets,
        "out_octets": out_octets,
        "in_ucast": in_ucast,
        "out_ucast": out_ucast,
        "in_mcast": in_mcast,
        "out_mcast": out_mcast,
        "in_bcast": in_bcast,
        "out_bcast": out_bcast,
        "in_disc": in_disc,
        "out_disc": out_disc,
        "in_err": in_err,
        "out_err": out_err,
        "in_util": in_util,
        "out_util": out_util,
        "speed": speed_mbps,
        "oper_status": int(oper_status),
    }
    
    msg = "%s: %s" % (item, ", ".join(details) if details else "up")
    
    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": metrics, "details": ""},
    }