_STATE_MAP = {0: "OK", 1: "WARN"}

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run([
            "snmpwalk", "-v2c", "-c", params.get("community", "public"),
            "-On", params.get("host", "localhost"),
            ".1.3.6.1.4.1.8691.10.2242.10.4.1.1"
        ], mutates=False)
        lines = res.stdout.splitlines()
        section = []
        for line in lines:
            parts = line.strip().split()
            if len(parts) < 2:
                continue
            oid_part = parts[0]
            value_part = " ".join(parts[1:]).lstrip()
            # Extract index from OID: .1.3.6.1.4.1.8691.10.2242.10.4.1.1.<index>
            oid_suffix = oid_part.rsplit(".", 1)[-1]
            # Parse value: TYPE: VALUE format
            if ":" in value_part:
                vtype, vstr = value_part.split(":", 1)
                vstr = vstr.strip()
            else:
                vstr = value_part.strip()
            section.append([oid_suffix, "", vstr])
        
        out = []
        for line in section:
            if line[2]:
                out.append({"item": line[0], "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d registers" % len(out),
                "data": {"discovery": out}}
    
    item = params.get("item", "")
    res = ctx.run([
        "snmpwalk", "-v2c", "-c", params.get("community", "public"),
        "-On", params.get("host", "localhost"),
        ".1.3.6.1.4.1.8691.10.2242.10.4.1.1"
    ], mutates=False)
    lines = res.stdout.splitlines()
    
    val = None
    summary = "Register not found"
    for line in lines:
        parts = line.strip().split()
        if len(parts) < 2:
            continue
        oid_part = parts[0]
        oid_index = oid_part.rsplit(".", 1)[-1]
        if oid_index != item:
            continue
        value_part = " ".join(parts[1:]).lstrip()
        if ":" in value_part:
            vtype, vstr = value_part.split(":", 1)
            vstr = vstr.strip()
        else:
            vstr = value_part.strip()
        if not vstr:
            val = None
            break
        if vstr.isdigit():
            val = int(vstr)
            summary = vstr
        else:
            val = None
        break
    
    if val == None:
        return {"changed": False, "msg": "Register not found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    if val in range(2):
        state = _STATE_MAP.get(val, "UNKNOWN")
    else:
        state = "UNKNOWN"
        summary = "Invalid value %s for register" % str(val)
    
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {}, "details": ""}}