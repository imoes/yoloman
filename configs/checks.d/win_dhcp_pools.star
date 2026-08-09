def main(ctx, params):
    if params.get("_discover"):
        # Discovery mode: gather DHCP pools from agent section win_dhcp_pools
        res = ctx.run(["cat", "/var/lib/dhcp_pools"], mutates=False)
        section = []
        if res.rc == 0 and res.stdout:
            for line in res.stdout.splitlines():
                line = line.rstrip(".").strip()
                if " = " in line:
                    parts = line.split(" = ", 1)
                    section.append(tuple(parts))
        
        in_block = False
        last_pool = ""
        pool_stats = []
        pools = []
        WIN_DHCP_POOLS_STATS_TRANSLATE = {
            "Entdeckungen": "Discovers",
            "Angebote": "Offers",
            "Anforderungen": "Requests",
            "Acks": "Acks",
            "Naks": "Nacks",
            "Abweisungen": "Declines",
            "Freigaben": "Releases",
            "Subnetz": "Subnet",
            "Bereiche": "Scopes",
            "Anzahl der verwendeten Adressen": "No. of Addresses in use",
            "Anzahl der freien Adressen": "No. of free Addresses",
            "Anzahl der anstehenden Angebote": "No. of pending offers",
            "D\u0082couvertes": "Discovers",
            "Offres": "Offers",
            "Requ\u0088tes": "Requests",
            "AR": "Acks",
            "AR n\u0082g.": "Nacks",
            "Refus": "Declines",
            "Lib\u0082rations": "Releases",
            "Sous-r\u0082seau": "Subnet",
            "\u0090tendues": "Scopes",
            "Nb d'adresses utilis\u0082es": "No. of Addresses in use",
            "Nb d'adresses libres": "No. of free Addresses",
            "Nb d'offres en attente": "No. of pending offers",
        }
        
        empty_pools = params.get("empty_pools", False)
        
        for line in section:
            key = line[0] if len(line) == 0 else line[0]
            translated_key = WIN_DHCP_POOLS_STATS_TRANSLATE.get(key, key)
            
            if translated_key == "Subnet":
                if in_block and len(pool_stats) >= 3:
                    used = pool_stats[0] if pool_stats[0] != None else 0
                    free = pool_stats[1] if pool_stats[1] != None else 0
                    pending = pool_stats[2] if pool_stats[2] != None else 0
                    size = used + free + pending
                    if size > 0 or empty_pools:
                        pools.append({
                            "item": last_pool,
                            "params": {"free_leases": (10.0, 5.0)},
                            "metrics": ["free_leases", "used_leases", "pending_leases"]
                        })
                
                in_block = True
                pool_stats = []
                last_pool = line[1] if len(line) > 1 else ""
                continue
            
            if in_block:
                key_normalized = translated_key
                if key_normalized == "No. of Addresses in use":
                    val_str = line[1].strip() if len(line) > 1 else ""
                    val = int(val_str) if val_str.isdigit() else 0
                    pool_stats.append(val)
                elif key_normalized == "No. of free Addresses":
                    val_str = line[1].strip() if len(line) > 1 else ""
                    val = int(val_str) if val_str.isdigit() else 0
                    pool_stats.append(val)
                elif key_normalized == "No. of pending offers":
                    val_str = line[1].strip() if len(line) > 1 else ""
                    val = int(val_str) if val_str.isdigit() else 0
                    pool_stats.append(val)
        
        # Final check for last pool
        if in_block and len(pool_stats) >= 3:
            used = pool_stats[0] if pool_stats[0] != None else 0
            free = pool_stats[1] if pool_stats[1] != None else 0
            pending = pool_stats[2] if pool_stats[2] != None else 0
            size = used + free + pending
            if size > 0 or empty_pools:
                pools.append({
                    "item": last_pool,
                    "params": {"free_leases": (10.0, 5.0)},
                    "metrics": ["free_leases", "used_leases", "pending_leases"]
                })
        
        return {
            "changed": False,
            "msg": "discovered %d pools" % len(pools),
            "data": {"discovery": pools}
        }
    
    # Check mode for specific item
    item = params.get("item", "")
    
    # Read agent data
    res = ctx.run(["cat", "/var/lib/dhcp_pools"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "DHCP pool data not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    section = []
    for line in res.stdout.splitlines():
        line = line.rstrip(".").strip()
        if " = " in line:
            parts = line.split(" = ", 1)
            section.append(tuple(parts))
    
    WIN_DHCP_POOLS_STATS_TRANSLATE = {
        "Entdeckungen": "Discovers",
        "Angebote": "Offers",
        "Anforderungen": "Requests",
        "Acks": "Acks",
        "Naks": "Nacks",
        "Abweisungen": "Declines",
        "Freigaben": "Releases",
        "Subnetz": "Subnet",
        "Bereiche": "Scopes",
        "Anzahl der verwendeten Adressen": "No. of Addresses in use",
        "Anzahl der freien Adressen": "No. of free Addresses",
        "Anzahl der anstehenden Angebote": "No. of pending offers",
        "D\u0082couvertes": "Discovers",
        "Offres": "Offers",
        "Requ\u0088tes": "Requests",
        "AR": "Acks",
        "AR n\u0082g.": "Nacks",
        "Refus": "Declines",
        "Lib\u0082rations": "Releases",
        "Sous-r\u0082seau": "Subnet",
        "\u0090tendues": "Scopes",
        "Nb d'adresses utilis\u0082es": "No. of Addresses in use",
        "Nb d'adresses libres": "No. of free Addresses",
        "Nb d'offres en attente": "No. of pending offers",
    }
    
    in_block = False
    pool_stats = []
    for line in section:
        key = line[0] if len(line) == 0 else line[0]
        translated_key = WIN_DHCP_POOLS_STATS_TRANSLATE.get(key, key)
        
        if translated_key == "Subnet" and line[1] == item:
            in_block = True
            pool_stats = []
            continue
        
        if in_block:
            key_normalized = translated_key
            if key_normalized == "No. of Addresses in use":
                val_str = line[1].strip() if len(line) > 1 else ""
                val = int(val_str) if val_str.isdigit() else 0
                pool_stats.append(val)
            elif key_normalized == "No. of free Addresses":
                val_str = line[1].strip() if len(line) > 1 else ""
                val = int(val_str) if val_str.isdigit() else 0
                pool_stats.append(val)
            elif key_normalized == "No. of pending offers":
                val_str = line[1].strip() if len(line) > 1 else ""
                val = int(val_str) if val_str.isdigit() else 0
                pool_stats.append(val)
            
            if len(pool_stats) == 3:
                break
    
    if len(pool_stats) != 3:
        return {
            "changed": False,
            "msg": "Pool information not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    used = pool_stats[0]
    free = pool_stats[1]
    pending = pool_stats[2]
    size = used + free + pending
    
    if size == 0:
        return {
            "changed": False,
            "msg": "DHCP Pool contains no IP addresses / is deactivated",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    free_leases = params.get("free_leases", (10.0, 5.0))
    warn = float(free_leases[0])
    crit = float(free_leases[1])
    
    state = "OK"
    if free <= crit:
        state = "CRIT"
    elif free <= warn:
        state = "WARN"
    
    return {
        "changed": False,
        "msg": "Free: %d, Used: %d, Pending: %d" % (free, used, pending),
        "data": {
            "state": state,
            "metrics": {
                "free_leases": free,
                "used_leases": used,
                "pending_leases": pending,
                "total_leases": size
            },
            "details": "Values are averaged, as the Windows DHCP plug-in collects statistics, not real-time measurements"
        }
    }