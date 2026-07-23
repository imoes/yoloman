def main(ctx, params):
    if params.get("_discover"):
        base_oid = ".1.3.6.1.4.1.2011.2.25.3.40.50.96.50.1"
        community = params.get("community", "public")
        host = params.get("host", "localhost")
        res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "SNMP walk failed", "data": {"discovery": []}}
        
        interfaces = {}
        for line in res.stdout.splitlines():
            if not line.strip():
                continue
            parts = line.strip().split(" = ")
            if len(parts) != 2:
                continue
            oid_full = parts[0].strip()
            value = parts[1].strip()
            oid_parts = oid_full.split(".")
            if len(oid_parts) < 13:
                continue
            
            base_idx = ".".join(oid_parts[-2:])
            if base_idx.startswith("3.200"):
                iface_name = value
                if iface_name not in interfaces:
                    interfaces[iface_name] = {"name": iface_name}
            elif base_idx.startswith("4."):
                if iface_name not in interfaces:
                    continue
                metric = base_idx.split(".")[1]
                val = int(value) if value.isdigit() else 0
                if metric == "113":
                    interfaces[iface_name]["rx_ucast"] = val
                elif metric == "114":
                    interfaces[iface_name]["rx_mcast"] = val
                elif metric == "115":
                    interfaces[iface_name]["rx_bcast"] = val
                elif metric == "116":
                    interfaces[iface_name]["tx_ucast"] = val
                elif metric == "117":
                    interfaces[iface_name]["tx_mcast"] = val
                elif metric == "118":
                    interfaces[iface_name]["tx_bcast"] = val
                elif metric == "200":
                    interfaces[iface_name]["rx_octets"] = val
                elif metric == "199":
                    interfaces[iface_name]["tx_octets"] = val
                elif metric == "944":
                    interfaces[iface_name]["rx_err"] = val
                elif metric == "945":
                    interfaces[iface_name]["tx_err"] = val
        
        discovery = []
        for name, data in interfaces.items():
            metrics = [
                "rx_octets",
                "tx_octets",
                "rx_ucast",
                "tx_ucast",
                "rx_mcast",
                "tx_mcast",
                "rx_bcast",
                "tx_bcast",
                "rx_err",
                "tx_err",
            ]
            discovery.append({
                "item": name,
                "params": {
                    "state": [1],
                    "speed": 0,
                    "InOctets": 0,
                    "OutOctets": 0,
                    "InUnicast": 0,
                    "OutUnicast": 0,
                    "InMulticast": 0,
                    "OutMulticast": 0,
                    "InBroadcast": 0,
                    "OutBroadcast": 0,
                    "InErrors": 0,
                    "OutErrors": 0,
                },
                "metrics": metrics,
            })
        
        return {
            "changed": False,
            "msg": "discovered %d interfaces" % len(discovery),
            "data": {"discovery": discovery},
        }
    
    item = params.get("item", "")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    base_oid = ".1.3.6.1.4.1.2011.2.25.3.40.50.96.50.1"
    
    res = ctx.run(["snmpwalk", "-v2c", "-c", community, "-On", host, base_oid], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "SNMP walk failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    interface_data = {}
    current_name = ""
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(" = ")
        if len(parts) != 2:
            continue
        oid_full = parts[0].strip()
        value = parts[1].strip()
        oid_parts = oid_full.split(".")
        if len(oid_parts) < 13:
            continue
        
        base_idx = ".".join(oid_parts[-2:])
        if base_idx.startswith("3.200"):
            current_name = value
            if current_name == item:
                interface_data["name"] = current_name
        elif base_idx.startswith("4."):
            if current_name != item:
                continue
            metric = base_idx.split(".")[1]
            val = int(value) if value.isdigit() else 0
            if metric == "113":
                interface_data["rx_ucast"] = val
            elif metric == "114":
                interface_data["rx_mcast"] = val
            elif metric == "115":
                interface_data["rx_bcast"] = val
            elif metric == "116":
                interface_data["tx_ucast"] = val
            elif metric == "117":
                interface_data["tx_mcast"] = val
            elif metric == "118":
                interface_data["tx_bcast"] = val
            elif metric == "200":
                interface_data["rx_octets"] = val
            elif metric == "199":
                interface_data["tx_octets"] = val
            elif metric == "944":
                interface_data["rx_err"] = val
            elif metric == "945":
                interface_data["tx_err"] = val
    
    if interface_data.get("name") != item:
        return {
            "changed": False,
            "msg": "interface %s not found" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    
    rx_octets = interface_data.get("rx_octets", 0)
    tx_octets = interface_data.get("tx_octets", 0)
    rx_ucast = interface_data.get("rx_ucast", 0)
    tx_ucast = interface_data.get("tx_ucast", 0)
    rx_mcast = interface_data.get("rx_mcast", 0)
    tx_mcast = interface_data.get("tx_mcast", 0)
    rx_bcast = interface_data.get("rx_bcast", 0)
    tx_bcast = interface_data.get("tx_bcast", 0)
    rx_err = interface_data.get("rx_err", 0)
    tx_err = interface_data.get("tx_err", 0)
    
    metrics = {
        "rx_octets": rx_octets,
        "tx_octets": tx_octets,
        "rx_ucast": rx_ucast,
        "tx_ucast": tx_ucast,
        "rx_mcast": rx_mcast,
        "tx_mcast": tx_mcast,
        "rx_bcast": rx_bcast,
        "tx_bcast": tx_bcast,
        "rx_err": rx_err,
        "tx_err": tx_err,
    }
    
    warn_err = params.get("errors", [0, 0])
    if type(warn_err) != "list":
        warn_err = [0, 0]
    warn_err = [warn_err[0], warn_err[1]]
    
    state = "OK"
    if rx_err >= warn_err[1] or tx_err >= warn_err[1]:
        state = "CRIT"
    elif rx_err >= warn_err[0] or tx_err >= warn_err[0]:
        state = "WARN"
    
    msg = "%s rx_octets: %d, tx_octets: %d, rx_err: %d, tx_err: %d" % (item, rx_octets, tx_octets, rx_err, tx_err)
    
    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": "",
        },
    }