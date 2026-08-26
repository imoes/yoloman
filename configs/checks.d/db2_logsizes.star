def parse_db2_dbs_lines(lines):
    current_instance = None
    dbs = {}
    global_timestamp = None
    for line in lines:
        parts = line.split()
        if len(parts) == 0:
            continue
        if parts[0].startswith("TIMESTAMP") and current_instance == None:
            global_timestamp = int(parts[1])
            continue
        if parts[0].startswith("[[["):
            current_instance = parts[0][3:-3]
            dbs[current_instance] = []
        elif current_instance != None:
            dbs[current_instance].append(parts)
    return global_timestamp, dbs

def parse_db2_logsizes(raw):
    global_timestamp, dbs = raw
    parsed = {}
    for key, values in dbs.items():
        instance_info = {}
        for value in values:
            field = value[0]
            rest = " ".join(value[1:])
            arr = instance_info.get(field, [])
            arr.append(rest)
            instance_info[field] = arr
        if "TIMESTAMP" not in instance_info and global_timestamp != None:
            instance_info["TIMESTAMP"] = [str(global_timestamp)]
        if "node" in instance_info:
            for node in instance_info["node"]:
                parsed["%s DPF %s" % (key, node)] = instance_info
        else:
            parsed[key] = instance_info
    return parsed

def is_int(s):
    s2 = s.strip()
    if s2 == "":
        return False
    i = 0
    if s2[0] == "-" or s2[0] == "+":
        i = 1
    if i >= len(s2):
        return False
    # BY INDEX: a Starlark string is NOT iterable, so `for c in s2[i:]:`
    # raises "string value is not iterable" at RUNTIME — on the very line that parses a
    # number out of device output. The stub validator only sees it when its empty-output
    # run happens to reach here, which is why nine shipped checks carried it.
    for _i_c in range(i, len(s2)):
        c = s2[_i_c]
        if c < "0" or c > "9":
            return False
    return True

def to_int(s):
    s2 = s.strip()
    neg = 1
    i = 0
    if len(s2) > 0 and (s2[0] == "-" or s2[0] == "+"):
        if s2[0] == "-":
            neg = -1
        i = 1
    result = 0
    for c in s2[i:]:
        result = result * 10 + (ord(c) - ord("0"))
    return neg * result

def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["db2dart", "-ver"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "db2 not installed", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "DB2 logsize monitoring requires a special agent; no local discovery available",
            "data": {"discovery": []},
        }

    item = params.get("item", "")
    return {
        "changed": False,
        "msg": "DB2 logsize check requires a DB2 special agent to gather data; no local source available",
        "data": {
            "state": "UNKNOWN",
            "metrics": {},
            "details": "Install the DB2 agent plugin to collect db2_logsizes data",
        },
    }