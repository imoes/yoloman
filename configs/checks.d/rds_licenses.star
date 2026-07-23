rds_licenses_product_versionid_map = {
    "8": "Windows Server 2025",
    "7": "Windows Server 2022",
    "6": "Windows Server 2019",
    "5": "Windows Server 2016",
    "4": "Windows Server 2012",
    "3": "Windows Server 2008 R2",
    "2": "Windows Server 2008",
}

def _license_levels(total, levels):
    if levels == False:
        return None, None
    if levels == None or (type(levels) == "list" and len(levels) == 0):
        return float(total), float(total)
    if type(levels) == "list" and len(levels) >= 2:
        if type(levels[0]) == "int":
            return float(max(0, total - levels[0])), float(max(0, total - levels[1]))
        if type(levels[0]) == "float" or type(levels[0]) == "int":
            return total * (1 - float(levels[0]) / 100.0), total * (1 - float(levels[1]) / 100.0)
    return None, None

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["type", "C:\\Windows\\Temp\\rds_licenses.txt"], mutates=False)
        if res.rc != 0:
            # Try alternate path if temp file not found
            res = ctx.run(["type", "C:\\ProgramData\\rds_licenses.txt"], mutates=False)
        if res.rc != 0:
            # No rds_licenses data available
            return {"changed": False, "msg": "no rds_licenses data available",
                    "data": {"discovery": []}}
        
        lines = res.stdout.splitlines()
        if len(lines) < 2:
            return {"changed": False, "msg": "no rds_licenses data available",
                    "data": {"discovery": []}}
        
        headers = lines[0].split(",")
        parsed = {}
        for line in lines[1:]:
            parts = line.split(",")
            if len(parts) < len(headers):
                continue
            data = {}
            for i in range(len(headers)):
                data[headers[i].strip()] = parts[i].strip() if i < len(parts) else ""
            version_id = data.get("ProductVersionID", "")
            if version_id not in rds_licenses_product_versionid_map:
                continue
            version = rds_licenses_product_versionid_map[version_id]
            if version not in parsed:
                parsed[version] = []
            parsed[version].append(data)
        
        discovery = []
        for item in parsed:
            discovery.append({"item": item, "params": {"levels": ["crit_on_all", None]},
                              "metrics": ["licenses"]})
        
        return {"changed": False, "msg": "discovered %d RDS license groups" % len(discovery),
                "data": {"discovery": discovery}}
    
    item = params.get("item", "")
    res = ctx.run(["type", "C:\\Windows\\Temp\\rds_licenses.txt"], mutates=False)
    if res.rc != 0:
        res = ctx.run(["type", "C:\\ProgramData\\rds_licenses.txt"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "no rds_licenses data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    lines = res.stdout.splitlines()
    if len(lines) < 2:
        return {"changed": False, "msg": "no rds_licenses data available",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    headers = lines[0].split(",")
    data_list = []
    for line in lines[1:]:
        parts = line.split(",")
        if len(parts) < len(headers):
            continue
        data = {}
        for i in range(len(headers)):
            data[headers[i].strip()] = parts[i].strip() if i < len(parts) else ""
        version_id = data.get("ProductVersionID", "")
        if version_id not in rds_licenses_product_versionid_map:
            continue
        version = rds_licenses_product_versionid_map[version_id]
        if version == item:
            data_list.append(data)
    
    if len(data_list) == 0:
        return {"changed": False, "msg": "no data for item " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    total = 0
    used = 0
    for pack in data_list:
        pack_total_str = pack.get("TotalLicenses", "0")
        pack_issued_str = pack.get("IssuedLicenses", "0")
        pack_total = int(pack_total_str) if pack_total_str.isdigit() else 0
        pack_issued = int(pack_issued_str) if pack_issued_str.isdigit() else 0
        total += pack_total
        used += pack_issued
    
    levels_param = params.get("levels", ["crit_on_all", None])
    warn, crit = _license_levels(total, levels_param)
    
    if used <= total:
        summary = "used %d out of %d licenses" % (used, total)
    else:
        summary = "used %d licenses, but you have only %d" % (used, total)
    
    state = "OK"
    if warn != None and crit != None:
        if used >= crit:
            state = "CRIT"
        elif used >= warn:
            state = "WARN"
        if state != "OK":
            summary += " (warn/crit at %d/%d)" % (int(warn), int(crit))
    
    metrics = {"licenses": float(used)}
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": metrics, "details": ""}}