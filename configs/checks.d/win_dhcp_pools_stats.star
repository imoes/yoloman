# Translation map for German/French keys to English
_WIN_DHCP_POOLS_STATS_TRANSLATE = {
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
    "Découvertes": "Discovers",
    "Offres": "Offers",
    "Requêtes": "Requests",
    "AR": "Acks",
    "AR nég.": "Nacks",
    "Refus": "Declines",
    "Libérations": "Releases",
    "Sous-réseau": "Subnet",
    "Étendues": "Scopes",
    "Nb d'adresses utilisées": "No. of Addresses in use",
    "Nb d'adresses libres": "No. of free Addresses",
    "Nb d'offres en attente": "No. of pending offers",
}

def _safe_int(raw):
    s = raw.strip()
    return int(s) if s.isdigit() or (s.startswith("-") and s[1:].isdigit()) else 0

def _get_rate(value_store, key, current_time, value):
    if not value_store.get(key):
        value_store[key] = [current_time, value]
        return 0.0
    prev_time, prev_value = value_store[key]
    time_diff = current_time - prev_time
    if time_diff <= 0:
        value_store[key] = [current_time, value]
        return 0.0
    rate = (value - prev_value) / time_diff
    if rate < 0:
        rate = 0.0
    value_store[key] = [current_time, value]
    return rate

def main(ctx, params):
    # Discovery mode: enumerate items
    if params.get("_discover"):
        res = ctx.run(["type", "C:\\Windows\\Temp\\cmk-agent-win-dhcp-pools.txt"], mutates=False)
        if res.rc != 0:
            res = ctx.run(["type", "C:\\ProgramData\\checkmk\\agent\\log\\cmk-agent-win-dhcp-pools.txt"], mutates=False)
        
        if res.rc != 0:
            return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
        
        section = []
        for line in res.stdout.splitlines():
            stripped = line.strip()
            if not stripped:
                continue
            idx = stripped.find(" = ")
            if idx != -1:
                key = stripped[:idx].rstrip(".")
                value = stripped[idx+3:].rstrip(".")
                section.append([key, value])
        
        # Discover DHCP Stats service (single-service check)
        has_entries = False
        for line in section:
            if len(line) > 0 and line[0]:
                has_entries = True
                break
        
        if has_entries:
            return {
                "changed": False,
                "msg": "discovered 1 service",
                "data": {"discovery": [
                    {"item": "", "params": {"free_leases": [10.0, 5.0]}, "metrics": [
                        "Discovers", "Offers", "Requests", "Acks", "Nacks", 
                        "Declines", "Releases", "Scopes"
                    ]}
                ]}
            }
        return {"changed": False, "msg": "discovered 0 items", "data": {"discovery": []}}
    
    # Check mode: process single item (item is "" for single-service check)
    item = params.get("item", "")
    if item:
        return {"changed": False, "msg": "DHCP Stats: item not expected", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    res = ctx.run(["type", "C:\\Windows\\Temp\\cmk-agent-win-dhcp-pools.txt"], mutates=False)
    if res.rc != 0:
        res = ctx.run(["type", "C:\\ProgramData\\checkmk\\agent\\log\\cmk-agent-win-dhcp-pools.txt"], mutates=False)
    
    if res.rc != 0:
        return {"changed": False, "msg": "DHCP Stats: no data available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    section = []
    for line in res.stdout.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        idx = stripped.find(" = ")
        if idx != -1:
            key = stripped[:idx].rstrip(".")
            value = stripped[idx+3:].rstrip(".")
            section.append([key, value])
    
    # Value store simulation (persist across checks)
    value_store = params.get("_value_store", {})
    current_time = ctx.facts().get("timestamp", 0)
    
    metrics = {}
    for line in section:
        if len(line) > 0:
            key = _WIN_DHCP_POOLS_STATS_TRANSLATE.get(line[0], line[0])
            if key in ["Discovers", "Offers", "Requests", "Acks", "Nacks", "Declines", "Releases", "Scopes"]:
                raw_value = line[1] if line[1] else "0"
                value = _safe_int(raw_value)
                rate = _get_rate(value_store, key, current_time, value)
                metrics[key] = rate
    
    # Store updated value store for next check
    params["_value_store"] = value_store
    
    # Build summary and details
    msg_parts = []
    for key in ["Discovers", "Offers", "Requests", "Acks", "Nacks", "Declines", "Releases", "Scopes"]:
        if metrics.get(key) != None:
            val = metrics[key]
            label = key
            msg_parts.append("%s: %d/s" % (label, int(val)))
    
    if not msg_parts:
        return {"changed": False, "msg": "DHCP Stats: no rate data available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    summary = ", ".join(msg_parts) + ", Values are averaged"
    details = "All values are averaged, as the Windows DHCP plug-in collects statistics, not real-time measurements"
    
    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": "OK",
            "metrics": metrics,
            "details": details,
        },
    }