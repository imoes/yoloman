def _detect_rittal_lcp(ctx, host, community):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.1.0"],
        mutates=False,
    )
    if res.rc != 0:
        return False
    val = res.stdout.strip()
    if val.startswith('"') and val.endswith('"') and len(val) >= 2:
        val = val[1:len(val) - 1]
    return val.startswith("Rittal LCP")


def _fetch_waterflow_tree(ctx, host, community):
    base = ".1.3.6.1.4.1.2606.7.4.2.2.1.10.2"
    oids = ["74", "75", "76", "77", "78", "79", "80", "81", "82", "83", "84", "85", "86", "87"]
    values = []
    for oid_suffix in oids:
        full_oid = base + "." + oid_suffix
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Oqv", host, full_oid],
            mutates=False,
        )
        if res.rc != 0:
            return None
        v = res.stdout.strip()
        if v.startswith('"') and v.endswith('"') and len(v) >= 2:
            v = v[1:len(v) - 1]
        values.append(v)
    return [values]


def parse_cmciii_lcp_waterflow(string_table):
    if not string_table:
        return None
    row = string_table[0]
    idx = 0
    name = None
    while idx < len(row):
        if "Waterflow" in row[idx]:
            name = row[idx]
            idx = idx + 1
            break
        idx = idx + 1
    if name == None:
        return None
    if idx + 3 >= len(row):
        return None
    flow_parts = row[idx].split(" ", 1)
    flow_str = flow_parts[0]
    unit = ""
    if len(flow_parts) > 1:
        unit = flow_parts[1]
    idx = idx + 1
    maxflow_str = row[idx].split(" ", 1)[0]
    idx = idx + 1
    minflow_str = row[idx].split(" ", 1)[0]
    idx = idx + 1
    status = row[idx]
    flow = float(flow_str)
    minflow = float(minflow_str)
    maxflow = float(maxflow_str)
    return {
        "name": name,
        "status": status,
        "unit": unit,
        "flow": flow,
        "minflow": minflow,
        "maxflow": maxflow,
    }


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        detected = _detect_rittal_lcp(ctx, host, community)
        if not detected:
            return {
                "changed": False,
                "msg": "no Rittal LCP device found",
                "data": {"discovery": []},
            }
        tree = _fetch_waterflow_tree(ctx, host, community)
        if tree == None:
            return {
                "changed": False,
                "msg": "no Rittal LCP device found",
                "data": {"discovery": []},
            }
        section = parse_cmciii_lcp_waterflow(tree)
        if section == None:
            return {
                "changed": False,
                "msg": "no Rittal LCP waterflow data found",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {},
                        "metrics": ["flow"],
                    }
                ]
            },
        }

    detected = _detect_rittal_lcp(ctx, host, community)
    if not detected:
        return {
            "changed": False,
            "msg": "no Rittal LCP device found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    tree = _fetch_waterflow_tree(ctx, host, community)
    if tree == None:
        return {
            "changed": False,
            "msg": "no Rittal LCP device found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    section = parse_cmciii_lcp_waterflow(tree)
    if section == None:
        return {
            "changed": False,
            "msg": "no Rittal LCP waterflow data found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    state = "OK"
    if section["status"] != "OK":
        state = "CRIT"
    elif section["flow"] < section["minflow"] or section["flow"] > section["maxflow"]:
        state = "WARN"

    summary = "%s Status: %s, Flow: %f %s" % (
        section["name"],
        section["status"],
        section["flow"],
        section["unit"],
    )

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {"flow": section["flow"]},
            "details": "",
        },
    }