# ===== hp_hh3c_ext — translated Checkmk SNMP check (read-only) =====

ADMIN_STATES = {
    "1": (1, "not_supported", "not supported"),
    "2": (0, "locked", "locked"),
    "3": (2, "shutting_down", "shutting down"),
    "4": (2, "unlocked", "unlocked"),
}

OPER_STATES = {
    "1": (1, "not_supported", "not supported"),
    "2": (2, "disabled", "disabled"),
    "3": (0, "enabled", "enabled"),
    "4": (2, "dangerous", "dangerous"),
}

SYS_OID = ".1.3.6.1.2.1.1.2.0"
ENT_BASE = ".1.3.6.1.4.1.25506.2.6.1.1.1.1"
NAME_BASE = ".1.3.6.1.2.1.47.1.1.1.1"


def _walk(ctx, community, host, col_oid):
    # -Oqn: "<col>.<index> <value>" per line, numeric OID, no type tag
    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, col_oid],
        mutates=False,
    )
    rows = []
    for line in res.stdout.splitlines():
        parts = line.split(" ", 1)
        if len(parts) != 2:
            continue
        oid = parts[0]
        val = parts[1]
        # index is the OID suffix after the column base
        idx = oid[len(col_oid) + 1:]
        rows.append((idx, val))
    return rows


def _get(ctx, community, host, oid):
    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
        mutates=False,
    )
    if res.rc != 0:
        return None
    return res.stdout.strip()


def _check_temp(ctx, params, name, index, temperature, mem_total, admin, oper):
    if temperature == 65535 or mem_total <= 0:
        return {"changed": False, "msg": "no valid sensor data for %s %s" % (name, index),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    warn = params.get("warn")
    crit = params.get("crit")
    temp = float(temperature)
    state = "OK"
    if warn != None and crit != None:
        if temp >= crit:
            state = "CRIT"
        elif temp >= warn:
            state = "WARN"
    elif crit != None:
        if temp >= crit:
            state = "CRIT"
        elif warn != None and temp >= warn:
            state = "WARN"
    # Checkmk default: warn=0, crit=0 -> always OK (no thresholds). Fall back to OK.
    metric_name = "temp"
    return {"changed": False, "msg": "Temperature: %f C" % temp,
            "data": {"state": state, "metrics": {metric_name: temp},
                     "details": "temperature=%f warn=%s crit=%s admin=%s oper=%s" %
                     (temp, warn, crit, admin, oper)}}


def _check_states(ctx, params, name, index, admin, oper):
    if admin == None or oper == None:
        return {"changed": False, "msg": "no state data for %s %s" % (name, index),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    st_admin, _k_a, rd_a = ADMIN_STATES.get(admin, (3, "unknown", "unknown[%s]" % admin))
    st_oper, _k_o, rd_o = OPER_STATES.get(oper, (3, "unknown", "unknown[%s]" % oper))
    # apply per-state overrides (0/1/2 numeric or string via int())
    ovr = params.get("admin_overrides", {})
    if admin in ovr:
        v = ovr[admin]
        st_admin = int(v) if isinstance(v, str) and v.isdigit() else int(v)
    ovr2 = params.get("oper_overrides", {})
    if oper in ovr2:
        v = ovr2[oper]
        st_oper = int(v) if isinstance(v, str) and v.isdigit() else int(v)
    # pick worst state
    worst = max(st_admin, st_oper)
    label_state = "OK"
    if worst == 1:
        label_state = "WARN"
    elif worst == 2:
        label_state = "CRIT"
    elif worst > 2:
        label_state = "UNKNOWN"
    summary = "Administrative: %s, Operational: %s" % (rd_a, rd_o)
    return {"changed": False, "msg": summary,
            "data": {"state": label_state, "metrics": {}, "details": summary}}


def _check_cpu(ctx, params, name, index, cpu):
    if cpu == None:
        return {"changed": False, "msg": "no cpu data for %s %s" % (name, index),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    util = float(cpu)
    warn = params.get("warn")
    crit = params.get("crit")
    state = "OK"
    if warn != None and crit != None:
        if util >= crit:
            state = "CRIT"
        elif util >= warn:
            state = "WARN"
    elif crit != None:
        if util >= crit:
            state = "CRIT"
        elif warn != None and util >= warn:
            state = "WARN"
    return {"changed": False, "msg": "CPU utilization: %f%%" % util,
            "data": {"state": state, "metrics": {"cpu": util},
                     "details": "cpu_util=%f" % util}}


def _check_mem(ctx, params, name, index, mem_used, mem_total):
    if mem_total <= 0:
        return {"changed": False, "msg": "no memory data for %s %s" % (name, index),
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    levels = params.get("levels")
    pct = 0.0
    if mem_total > 0:
        pct = 100.0 * mem_used / mem_total
    if levels != None:
        # levels[0] is int -> absolute bytes; else percentage tuple
        if isinstance(levels[0], int):
            # absolute: compare mem_used
            l0 = float(levels[0])
            l1 = float(levels[1])
            abs_used = float(mem_used)
            state = "OK"
            if abs_used >= l1:
                state = "CRIT"
            elif abs_used >= l0:
                state = "WARN"
        else:
            l0 = float(levels[0])
            l1 = float(levels[1])
            state = "OK"
            if pct >= l1:
                state = "CRIT"
            elif pct >= l0:
                state = "WARN"
    else:
        state = "OK"
    return {"changed": False, "msg": "Memory usage: %f%%" % pct,
            "data": {"state": state, "metrics": {"mem_used": mem_used, "mem_pct": pct},
                     "details": "mem_used=%f mem_total=%d pct=%f" % (mem_used, mem_total, pct)}}


def main(ctx, params):
    subcheck = params.get("subcheck", "temperature")
    community = params.get("community", "public")
    host = params.get("host", "localhost")
    item = params.get("item", "")

    # ---- probe: detect HH3c device via sysObjectID ----
    sys_oid_val = _get(ctx, community, host, SYS_OID)
    is_hh3c = False
    if sys_oid_val != None:
        if (sys_oid_val.startswith(".1.3.6.1.4.1.25506.11.1.239") or
            sys_oid_val.startswith(".1.3.6.1.4.1.25506.11.1.189") or
            sys_oid_val.startswith(".1.3.6.1.4.1.25506.11.1.87")):
            is_hh3c = True

    # ---- DISCOVERY MODE ----
    if params.get("_discover"):
        if not is_hh3c:
            return {"changed": False, "msg": "no HH3c device detected",
                    "data": {"discovery": []}}
        # walk entity table: index, admin(2), oper(3), cpu(6), mem_usage(12), temp(10) - wait OIDs
        # base oids from SNMPTree OIDs: OIDEnd() + 2 + 3 + 6 + 8 + 12 + 10
        # but SNMPTree fetches all columns at the same base with suffix indices 2,3,6,8,12,10
        # We walk each column OID separately
        cols = {
            "admin": ENT_BASE + ".2",
            "oper": ENT_BASE + ".3",
            "cpu": ENT_BASE + ".6",
            "mem_usage": ENT_BASE + ".8",
            "mem_size": ENT_BASE + ".10",
            "temperature": ENT_BASE + ".12",
        }
        walked = {}
        for key in cols:
            walked[key] = _walk(ctx, community, host, cols[key])
        # entity names: base .1.3.6.1.2.1.47.1.1.1.1, OIDEnd + OIDCached(2) => entPhysicalName
        name_oid = NAME_BASE + ".2"
        name_rows = _walk(ctx, community, host, name_oid)

        # correlate by index
        all_indices = set()
        for key in walked:
            for idx, _v in walked[key]:
                all_indices.add(idx)
        for idx, _v in name_rows:
            all_indices.add(idx)

        out = []
        for idx in sorted(all_indices):
            name_val = ""
            for nidx, nval in name_rows:
                if nidx == idx:
                    name_val = nval
                    break
            temp_v = _pick(walked["temperature"], idx)
            cpu_v = _pick(walked["cpu"], idx)
            mem_use_v = _pick(walked["mem_usage"], idx)
            mem_size_v = _pick(walked["mem_size"], idx)
            admin_v = _pick(walked["admin"], idx)
            oper_v = _pick(walked["oper"], idx)

            mem_total = 0
            try_int_temp = 0
            if mem_size_v != None:
                mem_total = _int_or_zero(mem_size_v)
            temp_val = _int_or_zero(temp_v) if temp_v != None else 65535
            if temp_val != 65535 and mem_total > 0:
                full_name = (name_val + " " + idx) if name_val else idx
                if subcheck == "temperature":
                    out.append({"item": full_name, "params": {"warn": 0, "crit": 0},
                                "metrics": ["temp"]})
                elif subcheck == "states":
                    out.append({"item": full_name, "params": {},
                                "metrics": []})
                elif subcheck == "cpu":
                    out.append({"item": full_name, "params": {"warn": 0, "crit": 0},
                                "metrics": ["cpu"]})
                elif subcheck == "mem":
                    out.append({"item": full_name, "params": {"levels": (80.0, 90.0)},
                                "metrics": ["mem_used", "mem_pct"]})
        return {"changed": False, "msg": "discovered %d items" % len(out),
                "data": {"discovery": out}}

    # ---- CHECK MODE ----
    # find this item's data
    # item is "name index" or just "index"
    target_index = item.rsplit(" ", 1)[-1] if " " in item else item

    temp_v = _get(ctx, community, host, ENT_BASE + ".12." + target_index)
    cpu_v = _get(ctx, community, host, ENT_BASE + ".6." + target_index)
    mem_use_v = _get(ctx, community, host, ENT_BASE + ".8." + target_index)
    mem_size_v = _get(ctx, community, host, ENT_BASE + ".10." + target_index)
    admin_v = _get(ctx, community, host, ENT_BASE + ".2." + target_index)
    oper_v = _get(ctx, community, host, ENT_BASE + ".3." + target_index)

    mem_total = 0
    if mem_size_v != None:
        mem_total = _int_or_zero(mem_size_v)
    if temp_v == None or cpu_v == None or mem_use_v == None or mem_size_v == None or mem_total <= 0:
        return {"changed": False, "msg": "no valid HH3c data for item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    temperature = _int_or_zero(temp_v)
    mem_used = 0.01 * _int_or_zero(mem_use_v) * mem_total
    cpu = _int_or_zero(cpu_v)

    if subcheck == "temperature":
        return _check_temp(ctx, params, item, target_index, temperature, admin_v, oper_v)
    elif subcheck == "states":
        return _check_states(ctx, params, item, target_index, admin_v, oper_v)
    elif subcheck == "cpu":
        return _check_cpu(ctx, params, item, target_index, cpu)
    elif subcheck == "mem":
        return _check_mem(ctx, params, item, target_index, mem_used, mem_total)
    return {"changed": False, "msg": "unknown subcheck: " + str(subcheck),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}


def _pick(rows, idx):
    for i, v in rows:
        if i == idx:
            return v
    return None


def _int_or_zero(s):
    if s == None:
        return 0
    stripped = s.strip()
    if stripped.lstrip("-").isdigit():
        return int(stripped)
    return 0