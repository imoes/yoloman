# Starlark module for checkmk.lnx_if interface check (read-only)
# Translated from Checkmk's cmk.plugins.network.agent_based.lnx_if

def _parse_dev_file(stdout):
    """Parse /proc/net/dev format into a dict of interface name -> counters"""
    result = {}
    lines = stdout.splitlines()
    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        # Format: "    eth0: 1234 56 7 8 0 0 0 0    1234 56 7 8 0 0 0 0"
        colon_idx = stripped.find(":")
        if colon_idx <= 0:
            continue
        name = stripped[:colon_idx].strip()
        rest = stripped[colon_idx+1:].strip()
        counters_str = rest.split()
        if len(counters_str) >= 16:
            counters = [int(x) for x in counters_str]
            result[name] = counters
    return result

def _parse_ip_link(stdout):
    """Parse 'ip -o link' output to extract interface info"""
    result = {}
    lines = stdout.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        # Format: "1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN mode DEFAULT group default"
        # Split on ": " to get fields
        parts = line.split()
        if len(parts) < 2 or not parts[1].endswith(":"):
            i += 1
            continue
        
        # Get interface name (second field, without trailing colon)
        full_name = parts[1][:-1]  # Remove trailing colon
        name = full_name.split("@")[0]  # Remove @suffix like veth123@eth0
        
        # Get flags from third field
        flags_part = ""
        if len(parts) > 2:
            flags_part = parts[2]
        
        # Extract state from flags
        state = ""
        if "<" in flags_part and ">" in flags_part:
            flag_str = flags_part[flags_part.find("<")+1:flags_part.find(">")]
            state = flag_str
        
        result[name] = {
            "state": state,
            "link_ether": "",
        }
        
        # Look for link/ether on next line(s)
        i += 1
        while i < len(lines):
            next_line = lines[i]
            stripped = next_line.strip()
            if not stripped:
                i += 1
                break
            if not stripped.startswith("link/"):
                i += 1
                continue
            if stripped.startswith("link/ether"):
                # link/ether 00:27:13:b4:a9:ec brd ff:ff:ff:ff:ff:ff
                parts = stripped.split()
                if len(parts) >= 2:
                    result[name]["link_ether"] = parts[1]
            i += 1
    
    return result

def _parse_ethtool(stdout):
    """Parse ethtool output to extract speed and link detected status"""
    result = {}
    lines = stdout.splitlines()
    current_iface = None
    
    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("[") and stripped.endswith("]"):
            current_iface = stripped[1:-1]
            result[current_iface] = {"speed": 0, "link_detected": ""}
            continue
        if current_iface == None:
            continue
        
        # Parse "Speed: 1000Mb/s"
        if stripped.startswith("Speed:"):
            speed_str = stripped[6:].strip()
            if speed_str == "65535Mb/s":
                result[current_iface]["speed"] = 0
            elif speed_str.endswith("Kb/s"):
                result[current_iface]["speed"] = int(float(speed_str[:-4])) * 1000
            elif speed_str.endswith("Mb/s"):
                result[current_iface]["speed"] = int(float(speed_str[:-4])) * 1000000
            elif speed_str.endswith("Gb/s"):
                result[current_iface]["speed"] = int(float(speed_str[:-4])) * 1000000000
            else:
                result[current_iface]["speed"] = 0
        # Parse "Link detected: yes/no"
        elif stripped.startswith("Link detected:"):
            result[current_iface]["link_detected"] = stripped[14:].strip()
    
    return result

def _get_oper_status(link_detected, state_infos, in_octets):
    """Determine operational status based on link detection, state, and traffic"""
    # From ethtool link detection
    if link_detected == "yes":
        return "1"
    if link_detected == "no":
        return "2"
    
    # From ip link state
    if state_infos:
        if "UP" in state_infos and "LOWER_UP" in state_infos:
            return "1"
        return "2"
    
    # Fallback: if ever seen traffic, assume up
    if in_octets > 0:
        return "1"
    return "4"

def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run(["cat", "/proc/net/dev"], mutates=False)
        dev_data = _parse_dev_file(res.stdout)
        
        res = ctx.run(["ip", "-o", "link"], mutates=False)
        ip_data = _parse_ip_link(res.stdout)
        
        res = ctx.run(["ethtool"] + list(dev_data.keys()), mutates=False)
        ethtool_data = _parse_ethtool(res.stdout)
        
        # Build discovered items
        out = []
        for iface_name in sorted(dev_data.keys()):
            counters = dev_data[iface_name]
            in_octets = counters[0]
            ip_info = ip_data.get(iface_name, {})
            eth_info = ethtool_data.get(iface_name, {})
            oper_status = _get_oper_status(
                eth_info.get("link_detected", ""),
                ip_info.get("state", ""),
                in_octets
            )
            
            # Skip veth* interfaces
            if iface_name.startswith("veth"):
                continue
            
            # Determine interface type
            iface_type = "24" if iface_name == "lo" else "6"
            
            # Build metrics list based on standard interface check
            metrics = [
                "in_octets", "in_ucast", "in_mcast", "in_bcast",
                "in_disc", "in_err", "out_octets", "out_ucast",
                "out_mcast", "out_bcast", "out_disc", "out_err"
            ]
            
            out.append({
                "item": iface_name,
                "params": {
                    "state": ["1"],  # up
                    "nonsingle_oper_status": ["1", "2", "4"]
                },
                "metrics": metrics
            })
        
        return {
            "changed": False,
            "msg": "discovered %d interfaces" % len(out),
            "data": {"discovery": out}
        }
    
    # Check mode (single item)
    item = params.get("item", "")
    if not item:
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Skip veth* interfaces
    if item.startswith("veth"):
        return {
            "changed": False,
            "msg": "interface %s is a docker veth interface" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    # Get data
    res = ctx.run(["cat", "/proc/net/dev"], mutates=False)
    dev_data = _parse_dev_file(res.stdout)
    
    res = ctx.run(["ip", "-o", "link", item], mutates=False)
    ip_data = _parse_ip_link(res.stdout)
    
    res = ctx.run(["ethtool", item], mutates=False)
    ethtool_data = _parse_ethtool(res.stdout)
    
    # Check if interface exists
    if item not in dev_data:
        return {
            "changed": False,
            "msg": "interface %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    counters = dev_data[item]
    in_octets = counters[0]
    in_ucast = counters[1] + counters[7]
    in_mcast = counters[7]
    in_bcast = 0
    in_disc = counters[3]
    in_err = counters[2]
    out_octets = counters[8]
    out_ucast = counters[9]
    out_mcast = 0
    out_bcast = 0
    out_disc = counters[11]
    out_err = counters[10]
    
    ip_info = ip_data.get(item, {})
    eth_info = ethtool_data.get(item, {})
    oper_status = _get_oper_status(
        eth_info.get("link_detected", ""),
        ip_info.get("state", ""),
        in_octets
    )
    
    # Get thresholds from params
    state_params = params.get("state", ["1"])  # up
    nonsingle_oper_status = params.get("nonsingle_oper_status", ["1", "2", "4"])
    
    # Determine state
    state = "OK"
    if oper_status not in state_params:
        if oper_status == "1":
            state = "CRIT"
        else:
            state = "WARN"
    
    # Build summary message
    speed = eth_info.get("speed", 0)
    speed_str = "unknown"
    if speed >= 1000000000:
        speed_str = "%f Gb/s" % (speed / 1000000000.0)
    elif speed >= 1000000:
        speed_str = "%f Mb/s" % (speed / 1000000.0)
    elif speed > 0:
        speed_str = "%d kb/s" % (speed / 1000)
    
    summary = "link %s" % ("up" if oper_status == "1" else "down")
    msg = "%s: %s, %s" % (item, speed_str, summary)
    
    # Build metrics
    metrics = {
        "in_octets": in_octets,
        "in_ucast": in_ucast,
        "in_mcast": in_mcast,
        "in_bcast": in_bcast,
        "in_disc": in_disc,
        "in_err": in_err,
        "out_octets": out_octets,
        "out_ucast": out_ucast,
        "out_mcast": out_mcast,
        "out_bcast": out_bcast,
        "out_disc": out_disc,
        "out_err": out_err
    }
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }