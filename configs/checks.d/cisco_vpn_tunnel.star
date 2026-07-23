# Top-level constant: SNMP OIDs for Cisco VPN tunnel data
# Phase 1 (IKE): base .1.3.6.1.4.1.9.9.171.1.2.3.1, OIDs: End, 7(remote_ip), 19(in), 27(out)
# Phase 2 (IPSec): base .1.3.6.1.4.1.9.9.171.1.3.2.1, OIDs: 2(tunnel_index), 3(alive), 26(in), 39(out)
OID_BASE_PHASE1 = ".1.3.6.1.4.1.9.9.171.1.2.3.1"
OID_BASE_PHASE2 = ".1.3.6.1.4.1.9.9.171.1.3.2.1"
OID_REMOTE_IP = "7"
OID_PHASE1_IN = "19"
OID_PHASE1_OUT = "27"
OID_TUNNEL_INDEX = "2"
OID_TUNNEL_ALIVE = "3"
OID_PHASE2_IN = "26"
OID_PHASE2_OUT = "39"

def _is_digits(s):
    # Check if string contains only digits
    if s == None:
        return False
    for c in s:
        if c < '0' or c > '9':
            return False
    return len(s) > 0

def _parse_snmp_int(s):
    # Safely parse SNMP integer strings; return 0 if invalid
    if s == None:
        return 0
    s = s.strip()
    if not _is_digits(s):
        return 0
    # Convert digit string to integer manually
    result = 0
    for c in s:
        result = result * 10 + (ord(c) - ord('0'))
    return result

def _format_bandwidth(n):
    # Convert to human-readable: bytes, KB/s, MB/s
    n = float(n)
    if n >= 1000.0 * 1000.0:
        return "%f MB/s" % (n / (1000.0 * 1000.0))
    elif n >= 1000.0:
        return "%f KB/s" % (n / 1000.0)
    else:
        return "%d B/s" % int(n)

def _parse_snmp_value(value_str):
    # Parse SNMP value string, handling STRING: and INTEGER: prefixes
    if value_str == None:
        return ""
    value_str = value_str.strip()
    if value_str.startswith("STRING:"):
        return value_str[7:].strip()
    elif value_str.startswith("INTEGER:"):
        return value_str[8:].strip()
    else:
        return value_str

def main(ctx, params):
    # Determine mode: discovery vs check
    if params.get("_discover") == True:
        # DISCOVERY MODE: enumerate all discovered VPN tunnels (by remote_ip)
        res1 = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            OID_BASE_PHASE1,
        ], mutates=False)
        res2 = ctx.run([
            "snmpwalk",
            "-v2c",
            "-c", params.get("community", "public"),
            "-On",
            params.get("host", "localhost"),
            OID_BASE_PHASE2,
        ], mutates=False)

        # Phase 1 parsing: collect (oid_end, remote_ip, in_octets, out_octets)
        phase1_by_ip = {}
        current_ip = ""
        current_index = ""
        
        for line in res1.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            parts = line.split(" = ", 1)
            if len(parts) != 2:
                continue
            oid_full, value_str = parts
            
            base_full = OID_BASE_PHASE1
            if oid_full.startswith(base_full + "."):
                suffix = oid_full[len(base_full)+1:]
                oid_parts2 = suffix.split(".", 1)
                if len(oid_parts2) < 2:
                    continue
                oid_num = oid_parts2[0]
                idx_num = oid_parts2[1]
                if not _is_digits(idx_num):
                    continue
                
                val = _parse_snmp_value(value_str)
                
                if oid_num == OID_REMOTE_IP:
                    current_ip = val
                    current_index = idx_num
                elif oid_num == OID_PHASE1_IN:
                    if current_ip and current_ip != "":
                        phase1_by_ip.setdefault(current_ip, {})["in"] = val
                        phase1_by_ip[current_ip]["index"] = current_index
                elif oid_num == OID_PHASE1_OUT:
                    if current_ip and current_ip != "":
                        phase1_by_ip.setdefault(current_ip, {})["out"] = val

        # Build tunnels: item = remote_ip (Phase 1 IP)
        discovery = []
        for remote_ip in phase1_by_ip:
            if remote_ip and remote_ip != "":
                metrics = ["if_in_octets", "if_out_octets"]
                discovery.append({
                    "item": remote_ip,
                    "params": {},
                    "metrics": metrics,
                })

        return {
            "changed": False,
            "msg": "discovered %d VPN tunnels" % len(discovery),
            "data": {"discovery": discovery},
        }

    # CHECK MODE: examine one tunnel by remote_ip
    item = params.get("item", "")
    
    res1 = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        OID_BASE_PHASE1,
    ], mutates=False)
    res2 = ctx.run([
        "snmpwalk",
        "-v2c",
        "-c", params.get("community", "public"),
        "-On",
        params.get("host", "localhost"),
        OID_BASE_PHASE2,
    ], mutates=False)

    # Parse Phase 1 data again, indexed by remote_ip
    phase1_by_ip = {}
    current_ip = ""
    current_index = ""
    
    for line in res1.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_full, value_str = parts
        
        base_full = OID_BASE_PHASE1
        if oid_full.startswith(base_full + "."):
            suffix = oid_full[len(base_full)+1:]
            oid_parts2 = suffix.split(".", 1)
            if len(oid_parts2) < 2:
                continue
            oid_num = oid_parts2[0]
            idx_num = oid_parts2[1]
            if not _is_digits(idx_num):
                continue
            
            val = _parse_snmp_value(value_str)
            
            if oid_num == OID_REMOTE_IP:
                current_ip = val
                current_index = idx_num
            elif oid_num == OID_PHASE1_IN:
                if current_ip and current_ip != "":
                    phase1_by_ip.setdefault(current_ip, {})["in"] = val
                    phase1_by_ip[current_ip]["index"] = current_index
            elif oid_num == OID_PHASE1_OUT:
                if current_ip and current_ip != "":
                    phase1_by_ip.setdefault(current_ip, {})["out"] = val

    # Parse Phase 2 data, indexed by tunnel_index
    phase2_by_index = {}
    current_idx = ""
    
    for line in res2.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid_full, value_str = parts
        
        base_full = OID_BASE_PHASE2
        if oid_full.startswith(base_full + "."):
            suffix = oid_full[len(base_full)+1:]
            oid_parts2 = suffix.split(".", 1)
            if len(oid_parts2) < 2:
                continue
            oid_num = oid_parts2[0]
            idx_num = oid_parts2[1]
            if not _is_digits(idx_num):
                continue
            
            val = _parse_snmp_value(value_str)
            
            if oid_num == OID_TUNNEL_INDEX:
                current_idx = val
            elif oid_num == OID_TUNNEL_ALIVE:
                if current_idx != "":
                    phase2_by_index.setdefault(current_idx, {})["alive"] = val
            elif oid_num == OID_PHASE2_IN:
                if current_idx != "":
                    phase2_by_index.setdefault(current_idx, {})["in"] = val
            elif oid_num == OID_PHASE2_OUT:
                if current_idx != "":
                    phase2_by_index.setdefault(current_idx, {})["out"] = val

    # Check for tunnel
    if not (item and item != "" and phase1_by_ip.get(item)):
        return {
            "changed": False,
            "msg": "Tunnel is missing",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    # Get Phase 1 values
    p1 = phase1_by_ip.get(item, {})
    phase1_in_str = p1.get("in", "0")
    phase1_out_str = p1.get("out", "0")
    phase1_in = _parse_snmp_int(phase1_in_str)
    phase1_out = _parse_snmp_int(phase1_out_str)

    # Get Phase 2 values (by Phase 1 index)
    idx = p1.get("index", "")
    p2 = phase2_by_index.get(idx, {})
    
    if p2 and idx != "":
        phase2_in_str = p2.get("in", "0")
        phase2_out_str = p2.get("out", "0")
        phase2_in = _parse_snmp_int(phase2_in_str)
        phase2_out = _parse_snmp_int(phase2_out_str)
        phase2_exists = True
    else:
        phase2_in = 0
        phase2_out = 0
        phase2_exists = False

    # Compute totals
    total_in = phase1_in + (phase2_in if phase2_exists else 0)
    total_out = phase1_out + (phase2_out if phase2_exists else 0)

    # Build summary message
    summary_parts = []
    summary_parts.append("Phase 1: in: %s, out: %s" % (
        _format_bandwidth(phase1_in), _format_bandwidth(phase1_out)))
    if phase2_exists:
        summary_parts.append("Phase 2: in: %s, out: %s" % (
            _format_bandwidth(phase2_in), _format_bandwidth(phase2_out)))
    else:
        summary_parts.append("Phase 2 missing")
    summary = "; ".join(summary_parts)

    # Metrics: if_in_octets, if_out_octets (total)
    metrics = {
        "if_in_octets": float(total_in),
        "if_out_octets": float(total_out),
    }

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": "OK",
            "metrics": metrics,
            "details": "",
        },
    }
