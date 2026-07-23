# Checkmk mssql_instance check translation to Starlark
MSSQL_VERSION_MAPPING = {
    "8": "2000",
    "9": "2005",
    "10": "2008",
    "10.50": "2008R2",
    "11": "2012",
    "12": "2014",
    "13": "2016",
    "14": "2017",
    "15": "2019",
    "16": "2022",
    "17": "2025",
}

def _parse_prod_version(entry):
    parts = entry.split(".", 2)
    if len(parts) < 2:
        return "unknown[%s]" % entry
    major = parts[0]
    minor = parts[1]
    key = "%s.%s" % (major, minor)
    version = MSSQL_VERSION_MAPPING.get(key)
    if version == None:
        version = MSSQL_VERSION_MAPPING.get(major)
    if version == None:
        return "unknown[%s]" % entry
    return "Microsoft SQL Server %s" % version

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["cat", "/var/lib/mk-agent/state/mssql_instance"], mutates=False)
        if res.rc != 0 or res.stdout == "":
            return {"changed": False, "msg": "discovered 0 instances",
                    "data": {"discovery": []}}
        sections = res.stdout.strip().split("\n\n")
        if len(sections) == 1 and sections[0].strip() == "":
            sections = []
        items = []
        for section in sections:
            lines = section.splitlines()
            parsed = {}
            for line in lines:
                if line == "" or line.strip() == "":
                    continue
                parts = line.split("|")
                if len(parts) < 2:
                    continue
                if parts[0].startswith("ERROR:"):
                    continue
                instance_id = parts[0]
                if instance_id.startswith("MSSQL_"):
                    instance_id = instance_id[6:]
                if instance_id not in parsed:
                    parsed[instance_id] = {"state": "0", "error_msg": "Unable to connect to database (Agent reported no state)"}
                if len(parts) < 3:
                    continue
                if parts[1] == "config":
                    if len(parts) >= 5:
                        parsed[instance_id].update({
                            "version_info": "%s - %s" % (parts[2], parts[3]),
                            "cluster_name": parts[4] if len(parts) > 4 else "",
                            "config_version": parts[2],
                            "config_edition": parts[3],
                        })
                elif parts[1] == "state":
                    if len(parts) >= 3:
                        error_msg = "|".join(parts[3:]) if len(parts) > 3 else ""
                        parsed[instance_id].update({
                            "state": parts[2],
                            "error_msg": error_msg,
                        })
                elif parts[1] == "details":
                    if len(parts) >= 5:
                        prod = _parse_prod_version(parts[2])
                        parsed[instance_id].update({
                            "prod_version_info": "%s (%s) (%s) - %s" % (prod, parts[3], parts[2], parts[4]),
                            "details_version": parts[2],
                            "details_product": prod,
                            "details_edition": parts[3],
                            "details_edition_long": parts[4],
                        })
            for instance_id in parsed:
                items.append({
                    "item": instance_id,
                    "params": {"map_connection_state": 2},
                    "metrics": []
                })
        return {"changed": False, "msg": "discovered %d instances" % len(items),
                "data": {"discovery": items}}
    
    item = params.get("item", "")
    res = ctx.run(["cat", "/var/lib/mk-agent/state/mssql_instance"], mutates=False)
    if res.rc != 0 or res.stdout == "":
        return {"changed": False, "msg": "Database or necessary processes not running or login failed",
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    
    sections = res.stdout.strip().split("\n\n")
    parsed = {}
    for section in sections:
        lines = section.splitlines()
        for line in lines:
            if line == "" or line.strip() == "":
                continue
            parts = line.split("|")
            if len(parts) < 2:
                continue
            if parts[0].startswith("ERROR:"):
                continue
            instance_id = parts[0]
            if instance_id.startswith("MSSQL_"):
                instance_id = instance_id[6:]
            if instance_id not in parsed:
                parsed[instance_id] = {"state": "0", "error_msg": "Unable to connect to database (Agent reported no state)"}
            if len(parts) < 3:
                continue
            if parts[1] == "config":
                if len(parts) >= 5:
                    parsed[instance_id].update({
                        "version_info": "%s - %s" % (parts[2], parts[3]),
                        "cluster_name": parts[4] if len(parts) > 4 else "",
                        "config_version": parts[2],
                        "config_edition": parts[3],
                    })
            elif parts[1] == "state":
                if len(parts) >= 3:
                    error_msg = "|".join(parts[3:]) if len(parts) > 3 else ""
                    parsed[instance_id].update({
                        "state": parts[2],
                        "error_msg": error_msg,
                    })
            elif parts[1] == "details":
                if len(parts) >= 5:
                    prod = _parse_prod_version(parts[2])
                    parsed[instance_id].update({
                        "prod_version_info": "%s (%s) (%s) - %s" % (prod, parts[3], parts[2], parts[4]),
                        "details_version": parts[2],
                        "details_product": prod,
                        "details_edition": parts[3],
                        "details_edition_long": parts[4],
                    })
    
    instance = parsed.get(item)
    if instance == None:
        return {"changed": False, "msg": "Database or necessary processes not running or login failed",
                "data": {"state": "CRIT", "metrics": {}, "details": ""}}
    
    map_state = params.get("map_connection_state", 2)
    state = map_state
    
    if instance["state"] == "0":
        msg = "Failed to connect to database (%s)" % instance["error_msg"]
        return {"changed": False, "msg": msg,
                "data": {"state": state, "metrics": {}, "details": ""}}
    
    version_info = instance.get("prod_version_info", instance["version_info"])
    summary = "Version: %s" % version_info
    if instance["cluster_name"] != "":
        summary = "%s, Clustered as %s" % (summary, instance["cluster_name"])
    return {"changed": False, "msg": summary,
            "data": {"state": 0, "metrics": {}, "details": ""}}