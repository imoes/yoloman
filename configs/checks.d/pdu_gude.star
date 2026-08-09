#!/usr/bin/env python3
# Starlark module — Checkmk check: pdu_gude (read-only)
# Monitors Gude PDU units over SNMP. Never mutates the system.

_GUDE_UNIT_SCALE = {
    "3":  ("kWh", 1000, "Total accumulated active energy"),
    "4":  ("W",   1,    "Active power"),
    "5":  ("A",   1000, "Current"),
    "6":  ("V",   1,    "Voltage"),
    "10": ("VA",  1,    "Mean apparent power"),
}

_GUDE_COL_ORDER = ["3", "4", "5", "6", "10"]

_GUDE_MODELS = {
    ".1.3.6.1.4.1.28507.26": ".1.3.6.1.4.1.28507.26.1.5.1.2.1",
    ".1.3.6.1.4.1.28507.27": ".1.3.6.1.4.1.28507.27.1.5.1.2.1",
    ".1.3.6.1.4.1.28507.62": ".1.3.6.1.4.1.28507.62.1.5.1.2.1",
    ".1.3.6.1.4.1.28507.41": ".1.3.6.1.4.1.28507.41.1.5.1.2.1",
}

_GUDE_DEFAULTS = {
    "V": (220, 210),
    "A": (15, 16),
    "W": (3500, 3600),
}

_WORST_ORDER = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}


def _detect(model_oid):
    return _GUDE_MODELS.get(model_oid)


def _to_float(s):
    if s == None or s == "":
        return None
    cleaned = ""
    started = False
    seen_dot = False
    for ch in s:
        if ch == "-" and not started:
            cleaned = cleaned + ch
            started = True
            continue
        if ch >= "0" and ch <= "9":
            cleaned = cleaned + ch
            started = True
        elif ch == "." and started == True and seen_dot == False:
            cleaned = cleaned + ch
            seen_dot = True
        else:
            if started == True:
                break
    if cleaned == "" or cleaned == "-" or cleaned == ".":
        return None
    return float(cleaned)


def _grade(value, params, unit):
    if unit not in params:
        return "OK", ""
    warn, crit = params[unit]
    if warn > crit:
        state = "OK"
        if value <= crit:
            state = "CRIT"
        elif value <= warn:
            state = "WARN"
        return state, "%s (warn<=%f, crit<=%f)" % (unit, warn, crit)
    state = "OK"
    if value >= crit:
        state = "CRIT"
    elif value >= warn:
        state = "WARN"
    return state, "%s (warn>=%f, crit>=%f)" % (unit, warn, crit)


def _worst(a, b):
    if _WORST_ORDER.get(a, 99) >= _WORST_ORDER.get(b, 99):
        return a
    return b


def _get_thresholds(params):
    eff = {}
    thresholds = params.get("pdu_gude", {})
    units = ["V", "A", "W", "VA", "kWh"]
    for u in units:
        if u in params:
            eff[u] = params[u]
        elif u in thresholds:
            eff[u] = thresholds[u]
        elif u in _GUDE_DEFAULTS:
            eff[u] = _GUDE_DEFAULTS[u]
    return eff


def _is_int(i):
    return type(i) == "int"


def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # --- DISCOVERY ---
    if params.get("_discover"):
        res = ctx.run(
            ["snmpget", "-v2c", "-c", community, "-Ovq", host,
             ".1.3.6.1.2.1.1.2.0"],
            mutates=False,
        )
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "no Gude PDU detected",
                    "data": {"discovery": []}}
        sysoid = res.stdout.strip()
        table_base = _detect(sysoid)
        if table_base == None:
            return {"changed": False, "msg": "no Gude PDU detected",
                    "data": {"discovery": []}}

        col3_oid = table_base + ".3"
        walk = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, col3_oid],
            mutates=False,
        )
        items = []
        if walk.rc == 0 and walk.stdout:
            prefix = col3_oid + "."
            for line in walk.stdout.splitlines():
                parts = line.split()
                if len(parts) < 2:
                    continue
                foid = parts[0]
                if foid.startswith(prefix):
                    idx = foid[len(prefix):]
                    if idx == "":
                        continue
                    if idx.isdigit():
                        items.append(int(idx))
                    else:
                        items.append(idx)
        else:
            single = table_base + ".1.3"
            gs = ctx.run(
                ["snmpget", "-v2c", "-c", community, "-Oqv", host, single],
                mutates=False,
            )
            if gs.rc == 0 and gs.stdout:
                items.append(1)
            else:
                return {"changed": False, "msg": "no Gude PDU detected",
                        "data": {"discovery": []}}

        if not items:
            return {"changed": False, "msg": "no Gude PDU detected",
                    "data": {"discovery": []}}

        all_int = True
        for i in items:
            if _is_int(i) == False:
                all_int = False
                break
        if all_int:
            items = sorted(items)
        else:
            items = sorted([str(i) for i in items])

        out = []
        for pdu_num in items:
            out.append({
                "item": "Phase %s" % str(pdu_num),
                "params": {"V": (220, 210), "A": (15, 16), "W": (3500, 3600)},
                "metrics": ["W", "A", "V", "VA", "kWh"],
            })
        return {"changed": False, "msg": "discovered %d PDU phases" % len(out),
                "data": {"discovery": out}}

    # --- CHECK MODE ---
    item = params.get("item", "")
    pdu_index = ""
    if item.startswith("Phase "):
        pdu_index = item[len("Phase "):]
    else:
        pdu_index = item

    eff_params = _get_thresholds(params)

    res = ctx.run(
        ["snmpget", "-v2c", "-c", community, "-Ovq", host,
         ".1.3.6.1.2.1.1.2.0"],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout:
        return {"changed": False,
                "msg": "no Gude PDU detected on %s" % host,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    sysoid = res.stdout.strip()
    table_base = _detect(sysoid)
    if table_base == None:
        return {"changed": False,
                "msg": "no Gude PDU detected on %s" % host,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    suffix = "." + str(pdu_index) if pdu_index != "" else ".1"
    col_oids = {}
    for col in _GUDE_COL_ORDER:
        col_oids[col] = table_base + "." + col + suffix

    values = {}
    for col in _GUDE_COL_ORDER:
        oid = col_oids[col]
        r = ctx.run(["snmpget", "-v2c", "-c", community, "-Oqv", host, oid],
                    mutates=False)
        if r.rc != 0 or not r.stdout:
            values[col] = None
        else:
            values[col] = _to_float(r.stdout.strip())

    metrics = {}
    details_lines = []
    summary_parts = []
    worst = "OK"

    for col in _GUDE_COL_ORDER:
        unit, scale, label = _GUDE_UNIT_SCALE[col]
        raw = values[col]
        if raw == None:
            return {"changed": False,
                    "msg": "incomplete data for Phase %s" % pdu_index,
                    "data": {"state": "UNKNOWN", "metrics": {},
                             "details": "missing column %s" % col}}
        scaled = raw / scale
        metrics[unit] = scaled
        st, desc = _grade(scaled, eff_params, unit)
        worst = _worst(worst, st)
        details_lines.append("%s: %f %s (%s)" % (label, scaled, unit, desc))
        summary_parts.append("%s=%f%s" % (unit, scaled, ""))

    summary = "Phase %s: %s" % (pdu_index, ", ".join(summary_parts))
    return {"changed": False, "msg": summary,
            "data": {"state": worst, "metrics": metrics,
                     "details": "\n".join(details_lines)}}