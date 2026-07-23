def main(ctx, params):
    # Discovery mode: enumerate MySQL instances with required keys
    if params.get("_discover"):
        res = ctx.run(["mysqladmin", "variables", "status"], mutates=False)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "discovered 0 instances",
                "data": {"discovery": []}
            }

        lines = res.stdout.splitlines()
        current_item = "mysql"
        sections = {}
        for line in lines:
            stripped = line.strip()
            if stripped.startswith("[[") and stripped.endswith("]]"):
                current_item = stripped.strip("[] ").strip()
                if current_item == "":
                    current_item = "mysql"
                sections[current_item] = []
            else:
                parts = stripped.split(None, 1)
                if len(parts) == 2:
                    key = parts[0]
                    val = parts[1]
                    if val.startswith("="):
                        val = val[1:].lstrip()
                    sections[current_item].append([key, val])

        discovered_items = []
        required_keys = ["Max_used_connections", "max_connections", "Threads_connected"]
        for item_name, entries in sections.items():
            data = {}
            for e in entries:
                k = e[0]
                v = e[1]
                norm_k = k.replace("-", "_").replace(" ", "_")
                if v.isdigit() or (v.startswith("-") and v[1:].isdigit()):
                    data[norm_k] = int(v)
                else:
                    data[norm_k] = v
            found_all = True
            for key in required_keys:
                if not (key in data):
                    found_all = False
                    break
            if found_all:
                discovered_items.append({
                    "item": item_name,
                    "params": {},
                    "metrics": ["connections_perc_used", "connections_perc_conn_threads"]
                })

        return {
            "changed": False,
            "msg": "discovered %d instances" % len(discovered_items),
            "data": {"discovery": discovered_items}
        }

    # Check mode: process single item
    item = params.get("item", "")
    res = ctx.run(["mysqladmin", "variables", "status"], mutates=False)
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "failed to query MySQL: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    lines = res.stdout.splitlines()
    current_item = "mysql"
    sections = {}
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("[[") and stripped.endswith("]]"):
            current_item = stripped.strip("[] ").strip()
            if current_item == "":
                current_item = "mysql"
            sections[current_item] = []
        else:
            parts = stripped.split(None, 1)
            if len(parts) == 2:
                key = parts[0]
                val = parts[1]
                if val.startswith("="):
                    val = val[1:].lstrip()
                sections[current_item].append([key, val])

    instance_data = {}
    for item_name, entries in sections.items():
        data = {}
        for e in entries:
            k = e[0]
            v = e[1]
            norm_k = k.replace("-", "_").replace(" ", "_")
            if v.isdigit() or (v.startswith("-") and v[1:].isdigit()):
                data[norm_k] = int(v)
            else:
                data[norm_k] = v
        instance_data[item_name] = data

    if not (item in instance_data):
        return {
            "changed": False,
            "msg": "MySQL instance not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    data = instance_data[item]
    if not ("Max_used_connections" in data and "max_connections" in data and "Threads_connected" in data):
        return {
            "changed": False,
            "msg": "Connection information is missing",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Validate that numeric fields can be converted
    max_used_str = str(data["Max_used_connections"])
    threads_str = str(data["Threads_connected"])
    max_conn_str = str(data["max_connections"])

    if not (max_used_str.isdigit() or (max_used_str.startswith("-") and max_used_str[1:].isdigit())):
        return {
            "changed": False,
            "msg": "Connection information is missing",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    if not (threads_str.isdigit() or (threads_str.startswith("-") and threads_str[1:].isdigit())):
        return {
            "changed": False,
            "msg": "Connection information is missing",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    if not (max_conn_str.isdigit() or (max_conn_str.startswith("-") and max_conn_str[1:].isdigit())):
        return {
            "changed": False,
            "msg": "Connection information is missing",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    conn = float(int(max_used_str))
    conn_threads = float(int(threads_str))
    max_conn = float(int(max_conn_str))

    if max_conn == 0:
        return {
            "changed": False,
            "msg": "max_connections is zero",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    perc_used = conn / max_conn * 100
    perc_conn_threads = conn_threads / max_conn * 100

    perc_used_levels = params.get("perc_used")
    perc_conn_threads_levels = params.get("perc_conn_threads")

    def get_state(value, levels):
        if levels == None:
            return "OK"
        upper = levels
        if type(upper) == "int" or type(upper) == "float":
            if value >= upper:
                return "CRIT"
            return "OK"
        if type(upper) == "list":
            if len(upper) >= 2:
                warn = upper[0]
                crit = upper[1]
                if value >= crit:
                    return "CRIT"
                if value >= warn:
                    return "WARN"
                return "OK"
            return "OK"
        return "OK"

    state = "OK"
    s1 = get_state(perc_used, perc_used_levels)
    if s1 == "CRIT":
        state = "CRIT"
    elif s1 == "WARN" and state == "OK":
        state = "WARN"
    s2 = get_state(perc_conn_threads, perc_conn_threads_levels)
    if s2 == "CRIT":
        state = "CRIT"
    elif s2 == "WARN" and state == "OK":
        state = "WARN"

    metrics = {
        "connections_perc_used": perc_used,
        "connections_max_used": conn,
        "connections_max": max_conn,
        "connections_perc_conn_threads": perc_conn_threads,
        "connections_conn_threads": conn_threads
    }

    msg = "Max. parallel connections since server start: %d%%, Currently open connections: %d%%" % (perc_used, perc_conn_threads)

    return {
        "changed": False,
        "msg": msg,
        "data": {"state": state, "metrics": metrics, "details": ""}
    }