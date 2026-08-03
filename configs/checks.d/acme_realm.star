def _map_state(state_code):
    map_states = {
        "3": (0, "in service"),
        "4": (1, "contraints violation"),
        "7": (2, "call load reduction"),
    }
    mapped = map_states.get(state_code, (3, "unknown"))
    return mapped[0], mapped[1]

def _safe_int(s):
    return int(s) if s.isdigit() else 0

def main(ctx, params):
    if params.get("_discover"):
        sys_oid = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", params.get("host", "localhost"), ".1.3.6.1.2.1.1.2.0"], mutates=False)
        if sys_oid.rc != 0 or not sys_oid.stdout:
            return {"changed": False, "msg": "no SNMP response", "data": {"discovery": []}}
        sys_oid_val = sys_oid.stdout.strip()
        acme_prefix = ".1.3.6.1.4.1.9148"
        if not sys_oid_val.startswith(acme_prefix):
            return {"changed": False, "msg": "not an ACME device", "data": {"discovery": []}}

        base_oid = ".1.3.6.1.4.1.9148.3.2.1.2.4.1"
        columns = ["2", "3", "5", "7", "11", "30"]
        col_names = ["name", "inbound", "outbound", "total_inbound", "total_outbound", "state"]

        col_data = {}
        for col, col_name in zip(columns, col_names):
            col_oid = base_oid + "." + col
            res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-Oqn", params.get("host", "localhost"), col_oid], mutates=False)
            if res.rc != 0 or not res.stdout:
                continue
            entries = []
            for line in res.stdout.splitlines():
                parts = line.split(" ", 1)
                if len(parts) != 2:
                    continue
                line_oid = parts[0]
                value = parts[1].strip()
                index = line_oid[len(col_oid) + 1:]
                entries.append((index, value))
            for index, value in entries:
                if index not in col_data:
                    col_data[index] = {}
                col_data[index][col_name] = value

        if not col_data:
            return {"changed": False, "msg": "no realms found", "data": {"discovery": []}}

        discovery = []
        for index, fields in col_data.items():
            if "name" not in fields:
                continue
            name = fields["name"].strip('"')
            discovery.append({"item": name, "params": {}, "metrics": ["inbound", "outbound"]})

        return {"changed": False, "msg": "discovered %d realms" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")

    base_oid = ".1.3.6.1.4.1.9148.3.2.1.2.4.1"
    columns = ["2", "3", "5", "7", "11", "30"]

    name_res = ctx.run(["snmpwalk", "-v2c", "-c", params.get("community", "public"), "-Oqn", params.get("host", "localhost"), base_oid + "." + columns[0]], mutates=False)
    if name_res.rc != 0 or not name_res.stdout:
        return {"changed": False, "msg": "no SNMP data for realm " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    target_index = None
    realm_name = None
    name_col_oid = base_oid + "." + columns[0]
    for line in name_res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        line_oid = parts[0]
        value = parts[1].strip()
        index = line_oid[len(name_col_oid) + 1:]
        value_stripped = value.strip('"')
        if value_stripped == item:
            target_index = index
            realm_name = value_stripped

    if target_index == None:
        return {"changed": False, "msg": "realm " + item + " not found", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    col_names = ["name", "inbound", "outbound", "total_inbound", "total_outbound", "state"]
    fields = {}
    for col, col_name in zip(columns, col_names):
        if col_name == "name":
            fields[col_name] = realm_name
        else:
            val_res = ctx.run(["snmpget", "-v2c", "-c", params.get("community", "public"), "-Oqv", params.get("host", "localhost"), base_oid + "." + col + "." + target_index], mutates=False)
            if val_res.rc != 0:
                return {"changed": False, "msg": "cannot read " + col_name, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
            fields[col_name] = val_res.stdout.strip()

    inbound = fields.get("inbound", "0")
    outbound = fields.get("outbound", "0")
    total_inbound = fields.get("total_inbound", "0")
    total_outbound = fields.get("total_outbound", "0")
    state_code = fields.get("state", "0")

    dev_state, dev_state_readable = _map_state(state_code)
    state_map = {0: "OK", 1: "WARN", 2: "CRIT", 3: "UNKNOWN"}
    state_str = state_map.get(dev_state, "UNKNOWN")

    summary = "Status: %s, Inbound: %s/%s, Outbound: %s/%s" % (dev_state_readable, inbound, total_inbound, outbound, total_outbound)

    metrics = {
        "inbound": _safe_int(repr(inbound).strip().strip('"')),
        "outbound": _safe_int(repr(outbound).strip().strip('"')),
    }

    return {"changed": False, "msg": summary, "data": {"state": state_str, "metrics": metrics, "details": ""}}