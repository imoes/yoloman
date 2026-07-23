HEADER = "PROTECTION_DOMAIN"
PD_PREFIX = "PROTECTION_DOMAIN_"
PD_PREFIX_LEN = 18  # len("PROTECTION_DOMAIN_")

def _parse_domains(stdout):
    domains = {}
    current_id = ""
    for line in stdout.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        if parts[0] == HEADER:
            current_id = parts[1].rstrip(":")
            domains[current_id] = {}
        elif current_id != "" and current_id in domains:
            domains[current_id][parts[0]] = parts[1:]
    return domains

def main(ctx, params):
    cmd = ["scli", "--query_all_protection_domains", "--approve_certificate"]
    mdm_ip = params.get("mdm_ip", "")
    if mdm_ip != "":
        cmd = ["scli", "--mdm_ip", mdm_ip, "--query_all_protection_domains", "--approve_certificate"]

    res = ctx.run(cmd, mutates=False)

    if params.get("_discover"):
        if res.rc != 0:
            return {"changed": False, "msg": "scli unavailable", "data": {"discovery": []}}
        domains = _parse_domains(res.stdout)
        items = [{"item": d_id, "params": {}, "metrics": []} for d_id in domains]
        return {
            "changed": False,
            "msg": "discovered %d protection domains" % len(items),
            "data": {"discovery": items},
        }

    if res.rc != 0:
        return {
            "changed": False,
            "msg": "scli failed: " + res.stderr,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    domains = _parse_domains(res.stdout)
    item = params.get("item", "")

    if item not in domains:
        return {
            "changed": False,
            "msg": "protection domain not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    fields = domains[item]

    state_list = fields.get("STATE")
    state_raw = state_list[0] if (state_list != None and len(state_list) > 0) else ""
    state_upper = state_raw.upper()
    status = state_upper[PD_PREFIX_LEN:] if state_upper.startswith(PD_PREFIX) else state_upper

    name_list = fields.get("NAME")
    name_val = name_list[0] if (name_list != None and len(name_list) > 0) else "unknown"

    check_state = "OK" if status == "ACTIVE" else "CRIT"

    return {
        "changed": False,
        "msg": "Name: %s, State: %s" % (name_val, status),
        "data": {"state": check_state, "metrics": {}, "details": ""},
    }