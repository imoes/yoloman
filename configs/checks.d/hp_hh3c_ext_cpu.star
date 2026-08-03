# ===== check plugin: hp_hh3c_ext_cpu =====
# Monitors CPU utilization (%) on HH3C (HP) devices via SNMP.

_CPU_TABLE_OID = ".1.3.6.1.4.1.25506.2.6.1.1.1.1"
_CPU_ADMIN_COL = "2"
_CPU_OPER_COL = "3"
_CPU_CPU_COL = "6"
_CPU_MEM_USAGE_COL = "8"
_CPU_TEMP_COL = "12"
_CPU_MEM_SIZE_COL = "10"

_ENTITY_TABLE_OID = ".1.3.6.1.2.1.47.1.1.1.1"
_ENTITY_NAME_COL = "2"

_DEFAULT_WARN = 80
_DEFAULT_CRIT = 90


def _to_int(s):
    return int(s) if s.isdigit() else 0


def _gather_section(ctx, host, community):
    cols = {
        _CPU_ADMIN_COL: "admin",
        _CPU_OPER_COL: "oper",
        _CPU_CPU_COL: "cpu",
        _CPU_MEM_USAGE_COL: "mem_usage",
        _CPU_TEMP_COL: "temp",
        _CPU_MEM_SIZE_COL: "mem_size",
    }

    col_data = {}
    for col_oid, col_name in cols.items():
        col_oid_full = _CPU_TABLE_OID + "." + col_oid
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, col_oid_full],
            mutates=False,
        )
        col_data[col_name] = {}
        if res.rc != 0 or not res.stdout:
            continue
        prefix = col_oid_full + "."
        for line in res.stdout.splitlines():
            sp = line.find(" ")
            if sp == -1:
                continue
            oid_part = line[:sp]
            val = line[sp + 1:]
            if oid_part.startswith(prefix):
                idx = oid_part[len(prefix):]
                col_data[col_name][idx] = val

    ent_res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host,
         _ENTITY_TABLE_OID + "." + _ENTITY_NAME_COL],
        mutates=False,
    )
    entity_names = {}
    if ent_res.rc == 0 and ent_res.stdout:
        ent_prefix = _ENTITY_TABLE_OID + "."
        name_suffix = "." + _ENTITY_NAME_COL
        for line in ent_res.stdout.splitlines():
            sp = line.find(" ")
            if sp == -1:
                continue
            oid_part = line[:sp]
            val = line[sp + 1:]
            if oid_part.startswith(ent_prefix) and oid_part.endswith(name_suffix):
                suffix = oid_part[len(ent_prefix):]
                idx = suffix[:-(len(name_suffix))]
                entity_names[idx] = val

    parsed = {}
    indices = set(col_data["cpu"].keys())
    for idx in indices:
        cpu_val = col_data["cpu"].get(idx, "0")
        mem_size_val = col_data["mem_size"].get(idx, "0")
        mem_usage_val = col_data["mem_usage"].get(idx, "0")
        temp_val = col_data["temp"].get(idx, "65535")
        admin_val = col_data["admin"].get(idx, "")
        oper_val = col_data["oper"].get(idx, "")

        mem_total = _to_int(mem_size_val)
        mem_used = 0.01 * _to_int(mem_usage_val) * mem_total
        temp = _to_int(temp_val)
        cpu = _to_int(cpu_val)

        name = entity_names.get(idx, "")
        item_name = (name + " " + idx) if name else idx
        parsed.setdefault(item_name, {
            "temp": temp,
            "cpu": cpu,
            "mem_total": mem_total,
            "mem_used": mem_used,
            "admin": admin_val,
            "oper": oper_val,
        })
    return parsed


def _is_hh3c(ctx, host, community):
    soid_res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if soid_res.rc != 0 or not soid_res.stdout:
        return False
    soid = soid_res.stdout.strip()
    return (
        soid.startswith(".1.3.6.1.4.1.25506.11.1.239") or
        soid.startswith(".1.3.6.1.4.1.25506.11.1.189") or
        soid.startswith(".1.3.6.1.4.1.25506.11.1.87")
    )


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")
    warn = params.get("warn", _DEFAULT_WARN)
    crit = params.get("crit", _DEFAULT_CRIT)

    if params.get("_discover"):
        if not _is_hh3c(ctx, host, community):
            return {"changed": False, "msg": "not installed", "data": {"discovery": []}}

        section = _gather_section(ctx, host, community)
        discovery = []
        for name, data in section.items():
            if data["mem_total"] > 0:
                discovery.append({
                    "item": name,
                    "params": {"warn": warn, "crit": crit},
                    "metrics": ["cpu_util"],
                })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")

    if not _is_hh3c(ctx, host, community):
        return {
            "changed": False,
            "msg": "not an HH3C device",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    section = _gather_section(ctx, host, community)
    data = section.get(item)
    if data == None:
        return {
            "changed": False,
            "msg": "no such item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    cpu = data["cpu"]
    state = "CRIT" if cpu >= crit else ("WARN" if cpu >= warn else "OK")
    return {
        "changed": False,
        "msg": "CPU utilization %d%%" % cpu,
        "data": {
            "state": state,
            "metrics": {"cpu_util": cpu},
            "details": "",
        },
    }