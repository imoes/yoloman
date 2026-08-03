def parse_crs_res(string_table):
    crs_nodename = None
    raw_resources = {}
    entry = {}
    res_name = None
    for line in string_table:
        if len(line) == 1:
            nodename, varsetting = None, line[0]
        else:
            nodename, varsetting = line[0], line[1]
        if nodename == "nodename":
            crs_nodename = varsetting
            continue
        parts = varsetting.split("=", 1)
        if len(parts) != 2:
            continue
        key, value = parts[0], parts[1]
        if key == "NAME":
            res_name = value
            if res_name not in raw_resources:
                raw_resources[res_name] = {}
            raw_resources[res_name][nodename] = {}
        else:
            if res_name != None and nodename in raw_resources[res_name]:
                raw_resources[res_name][nodename][key.lower()] = value
    return crs_nodename, raw_resources


def read_crs_res(ora_res_path, ctx):
    if ctx.file_exists(ora_res_path):
        content = ctx.file_read(ora_res_path)
        lines = content.split("\n")
        string_table = []
        for l in lines:
            if l.strip() == "":
                continue
            fields = l.split("|", 1)
            string_table.append(fields)
        return string_table
    return None


def main(ctx, params):
    ora_res_path = params.get("ora_res_path", "/usr/local/checkmk/oracle_crs_res")
    if params.get("_discover"):
        string_table = read_crs_res(ora_res_path, ctx)
        if string_table == None:
            return {"changed": False, "msg": "no oracle CRS data found",
                    "data": {"discovery": []}}
        crs_nodename, raw_resources = parse_crs_res(string_table)
        discovery = []
        for item in raw_resources:
            discovery.append({"item": item, "params": {"number_of_nodes_not_in_target_state": [1, 2]},
                             "metrics": ["oracle_number_of_nodes_not_in_target_state"]})
        return {"changed": False, "msg": "discovered %d resources" % len(discovery),
                "data": {"discovery": discovery}}
    item = params.get("item", "")
    string_table = read_crs_res(ora_res_path, ctx)
    if string_table == None:
        return {"changed": False, "msg": "no oracle CRS data found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    crs_nodename, raw_resources = parse_crs_res(string_table)
    if item not in raw_resources:
        if item == "ora.cssd":
            return {"changed": False, "msg": "Clusterware not running",
                    "data": {"state": "CRIT", "metrics": {}, "details": ""}}
        elif item == "ora.crsd":
            return {"changed": False, "msg": "Cluster resource service daemon not running",
                    "data": {"state": "CRIT", "metrics": {}, "details": ""}}
        return {"changed": False, "msg": "No resource details found for %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    nodes_info = raw_resources[item]
    number_of_nodes_not_in_target_state = 0
    summary = ""
    for nodename, entry in nodes_info.items():
        resstate = entry.get("state", "")
        if " " in resstate:
            resstate = resstate.split(" ", 1)[0]
        restarget = entry.get("target", "")
        if nodename == "csslocal":
            infotext = "local: "
        elif nodename != None and nodename != "":
            infotext = "on " + nodename + ": "
        else:
            infotext = ""
        infotext += resstate.lower()
        if resstate != restarget:
            number_of_nodes_not_in_target_state += 1
            infotext += ", target state " + restarget.lower()
        if summary:
            summary = summary + "; " + infotext
        else:
            summary = infotext
    levels = params.get("number_of_nodes_not_in_target_state", [1, 2])
    warn = levels[0] if len(levels) > 0 else 1
    crit = levels[1] if len(levels) > 1 else 2
    state = "CRIT" if number_of_nodes_not_in_target_state >= crit else ("WARN" if number_of_nodes_not_in_target_state >= warn else "OK")
    return {"changed": False, "msg": summary,
            "data": {"state": state, "metrics": {"oracle_number_of_nodes_not_in_target_state": number_of_nodes_not_in_target_state},
                     "details": ""}}