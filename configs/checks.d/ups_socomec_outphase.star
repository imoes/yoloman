BASE_OID = ".1.3.6.1.4.1.4555.1.1.1.1.4.4.1"

def _snmp_val(raw):
    if ": " in raw:
        return raw.split(": ", 1)[1].strip()
    return raw.strip()

def _safe_int(s):
    s = s.strip()
    neg = s.startswith("-")
    digits = s[1:] if neg else s
    if digits.isdigit():
        return int(s)
    return 0

def _row_key(r):
    return int(r) if r.isdigit() else 0

def _parse_table(stdout):
    rows = {}
    prefix = BASE_OID + "."
    for line in stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        eq_idx = line.find(" = ")
        if eq_idx < 0:
            continue
        oid = line[:eq_idx].strip()
        raw_val = line[eq_idx + 3:]
        if not oid.startswith(prefix):
            continue
        rest = oid[len(prefix):]
        dot_idx = rest.find(".")
        if dot_idx < 0:
            continue
        col = rest[:dot_idx]
        row = rest[dot_idx + 1:]
        if row not in rows:
            rows[row] = {}
        rows[row][col] = _snmp_val(raw_val)
    return rows

def _build_phases(rows):
    phases = []
    for row in sorted(rows.keys(), key=_row_key):
        cols = rows[row]
        index = cols.get("1", row)
        voltage = _safe_int(cols.get("2", "0")) // 10
        current = _safe_int(cols.get("3", "0")) // 10
        output_load = _safe_int(cols.get("4", "0"))
        phases.append({
            "item": "Phase " + index,
            "voltage": voltage,
            "current": current,
            "output_load": output_load,
        })
    return phases

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    if params.get("_discover"):
        res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-On", host, BASE_OID],
            mutates=False,
        )
        if res.rc != 0 or not res.stdout.strip():
            return {
                "changed": False,
                "msg": "SNMP walk failed or no data",
                "data": {"discovery": []},
            }
        rows = _parse_table(res.stdout)
        phases = _build_phases(rows)
        discovery = [
            {
                "item": p["item"],
                "params": {"voltage": [210, 200], "output_load": [80, 90]},
                "metrics": ["voltage", "current", "output_load"],
            }
            for p in phases
        ]
        return {
            "changed": False,
            "msg": "discovered %d phases" % len(discovery),
            "data": {"discovery": discovery},
        }

    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    if not item.startswith("Phase"):
        item = "Phase " + item

    volt_levels = params.get("voltage", [210, 200])
    volt_warn = volt_levels[0]
    volt_crit = volt_levels[1]
    load_levels = params.get("output_load", [80, 90])
    load_warn = load_levels[0]
    load_crit = load_levels[1]
    curr_levels = params.get("current", None)

    res = ctx.run(
        ["snmpwalk", "-v2c", "-c", community, "-On", host, BASE_OID],
        mutates=False,
    )
    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "SNMP walk failed: " + res.stderr.strip(),
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    rows = _parse_table(res.stdout)
    phases = _build_phases(rows)

    found = None
    for p in phases:
        if p["item"] == item:
            found = p
            break

    if found == None:
        return {
            "changed": False,
            "msg": item + " not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    voltage = found["voltage"]
    current = found["current"]
    output_load = found["output_load"]

    state = "OK"
    issues = []

    # Voltage: lower bound — CRIT takes precedence
    if voltage <= volt_crit:
        state = "CRIT"
        issues.append("Voltage %dV <= %dV" % (voltage, volt_crit))
    elif voltage <= volt_warn:
        state = "WARN"
        issues.append("Voltage %dV <= %dV" % (voltage, volt_warn))

    # Output load: upper bound
    if output_load >= load_crit:
        state = "CRIT"
        issues.append("Load %d%% >= %d%%" % (output_load, load_crit))
    elif output_load >= load_warn:
        if state != "CRIT":
            state = "WARN"
        issues.append("Load %d%% >= %d%%" % (output_load, load_warn))

    # Current: optional upper bound
    if curr_levels != None:
        curr_warn = curr_levels[0]
        curr_crit = curr_levels[1]
        if current >= curr_crit:
            state = "CRIT"
            issues.append("Current %dA >= %dA" % (current, curr_crit))
        elif current >= curr_warn:
            if state != "CRIT":
                state = "WARN"
            issues.append("Current %dA >= %dA" % (current, curr_warn))

    summary = "Voltage: %dV, Current: %dA, Load: %d%%" % (voltage, current, output_load)
    if issues:
        summary = summary + " - " + ", ".join(issues)

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": {
                "voltage": voltage,
                "current": current,
                "output_load": output_load,
            },
            "details": "",
        },
    }