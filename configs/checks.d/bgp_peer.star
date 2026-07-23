def _convert_address(value):
    if type(value) == "list":
        if len(value) == 4:
            return str(value[0]) + "." + str(value[1]) + "." + str(value[2]) + "." + str(value[3])
        elif len(value) == 16:
            groups = []
            for i in range(0, 16, 2):
                val = value[i] * 256 + value[i+1]
                hex_val = ""
                if val == 0:
                    hex_val = "0"
                else:
                    temp = val
                    while temp > 0:
                        digit = temp % 16
                        if digit < 10:
                            hex_val = str(digit) + hex_val
                        else:
                            hex_val = chr(ord('a') + digit - 10) + hex_val
                        temp = temp // 16
                groups.append(hex_val)
            return ":".join(groups)
        return "unknown(%s)" % str(value)
    return str(value)

def _parse_oid_end(oid_end_str):
    parts = oid_end_str.split(".")
    ip = ""
    if len(parts) >= 4:
        ip = str(parts[-4]) + "." + str(parts[-3]) + "." + str(parts[-2]) + "." + str(parts[-1])
    else:
        ip = "0.0.0.0"
    return ip

def _extract_int(s):
    return int(s) if s.isdigit() else 0

def _get_state_name(state_str):
    return {
        "1": "idle",
        "2": "connect",
        "3": "active",
        "4": "opensent",
        "5": "openconfirm",
        "6": "established"
    }.get(state_str, "unknown")

def _get_admin_name(state_str):
    return {
        "1": "halted",
        "2": "running"
    }.get(state_str, "unknown")

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.30065.4.1.1.2.1"
        ], mutates=False)
        
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "SNMP error: " + res.stderr,
                "data": {"discovery": []}
            }
        
        peers = {}
        for line in res.stdout.splitlines():
            if "=" not in line:
                continue
            oid, value = line.strip().split("=", 1)
            oid = oid.strip()
            value = value.strip()
            
            if "PeerRemoteAddr" in oid or "PeerRemoteAs" in oid:
                ip = _parse_oid_end(oid.split(".")[-1])
                if ip not in peers:
                    peers[ip] = {}
        
        discovery_list = []
        for ip in peers:
            discovery_list.append({
                "item": ip,
                "params": {
                    "admin_state_mapping": {"halted": 0, "running": 0},
                    "peer_state_mapping": {
                        "idle": 0,
                        "connect": 0,
                        "active": 0,
                        "opensent": 0,
                        "openconfirm": 0,
                        "established": 0
                    }
                },
                "metrics": ["uptime"]
            })
        
        return {
            "changed": False,
            "msg": "discovered %d BGP peers" % len(discovery_list),
            "data": {"discovery": discovery_list}
        }

    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    
    ip_parts = item.split(".")
    if len(ip_parts) != 4:
        return {
            "changed": False,
            "msg": "invalid IP format",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    base_oid = ".1.3.6.1.4.1.30065.4.1.1.2.1"
    
    admin_oid = base_oid + ".12.1.4." + item
    state_oid = base_oid + ".13.1.4." + item
    description_oid = base_oid + ".14.1.4." + item
    last_error_oid = base_oid + ".3.1.4." + item
    established_oid = base_oid + ".4.1.1.4." + item
    
    def get_oid(oid):
        res = ctx.run(["snmpget", "-v2c", "-c", community, "-On", host, oid], mutates=False)
        if res.rc != 0 or "=" not in res.stdout:
            return None
        _, val = res.stdout.strip().split("=", 1)
        return val.strip()
    
    admin_status = get_oid(admin_oid)
    state = get_oid(state_oid)
    description = get_oid(description_oid)
    established_time = get_oid(established_oid)
    
    if admin_status == None or state == None:
        return {
            "changed": False,
            "msg": "no data for peer " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    admin_state_val = admin_status.split(":")[-1].strip() if ":" in admin_status else admin_status
    state_val = state.split(":")[-1].strip() if ":" in state else state
    established_val = int(established_time.split(":")[-1].strip()) if established_time and ":" in established_time else 0
    desc_val = description.split(":")[-1].strip() if description else "n/a"
    
    admin_map = params.get("admin_state_mapping", {"halted": 0, "running": 0})
    peer_map = params.get("peer_state_mapping", {
        "idle": 0, "connect": 0, "active": 0, "opensent": 0, "openconfirm": 0, "established": 0
    })
    
    admin_name = _get_admin_name(admin_state_val)
    peer_name = _get_state_name(state_val)
    
    admin_state_code = admin_map.get(admin_name, 3)
    peer_state_code = peer_map.get(peer_name, 3)
    
    if admin_name != "running" or peer_name != "established":
        if admin_name != "running":
            state_code = 2
        else:
            state_code = 1
    else:
        state_code = 0
    
    details = ""
    if desc_val and desc_val != "n/a":
        details += "Description: " + desc_val + ", "
    
    summary_parts = []
    summary_parts.append("Admin state: " + admin_name)
    summary_parts.append("Peer state: " + peer_name)
    summary_parts.append("Established time: " + str(established_val) + "s")
    
    return {
        "changed": False,
        "msg": ", ".join(summary_parts),
        "data": {
            "state": ["OK", "WARN", "CRIT", "UNKNOWN"][state_code],
            "metrics": {"uptime": established_val},
            "details": details
        }
    }