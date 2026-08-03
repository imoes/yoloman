def _to_float(s):
    v = s.strip()
    if v == "":
        return None
    # Accept optional leading +/-, digits, optional decimal point and digits.
    body = v
    neg = False
    if body.startswith("-"):
        neg = True
        body = body[1:]
    elif body.startswith("+"):
        body = body[1:]
    if body == "":
        return None
    # Must contain at least one digit.
    digits = body.replace(".", "", 1)
    if digits == "" or not digits.isdigit():
        return None
    f = float(body)
    if neg:
        f = 0 - f
    return f

def _grade(value, warn, crit):
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"

def main(ctx, params):
    host = params.get("host", "localhost")
    community = params.get("community", "public")

    # OID layout from SimpleSNMPSection fetch:
    #   col1 = .1.11.2.4.2.1.1.1  (raw_temp, in tenths of a degree)
    #   col2 = .1.11.2.4.2.1.2   (raw_high, in tenths)
    #   col3 = .1.11.2.4.2.1.3   (raw_low, in tenths)
    #   col4 = .2.5.5.1.1.1      (description)
    #   col5 = .2.5.5.2.1.5      (name)
    # base = .1.3.6.1.4.1.2544
    base = "1.3.6.1.4.1.2544"
    col_temp = base + ".1.11.2.4.2.1.1.1"
    col_high = base + ".1.11.2.4.2.1.2"
    col_low = base + ".1.11.2.4.2.1.3"
    col_desc = base + ".2.5.5.1.1.1"
    col_name = base + ".2.5.5.2.1.5"

    warn = params.get("warn")
    crit = params.get("crit")
    levels = params.get("levels")
    if levels != None:
        warn = levels[0]
        crit = levels[1]
    if warn == None:
        warn = 70
    if crit == None:
        crit = 80

    if params.get("_discover"):
        # Probe sysoid first: only discover on an ADVA FSP.
        sys_descr_res = ctx.run(
            [
                "snmpget", "-v2c", "-c", community, "-Oqv",
                host, "1.3.6.1.2.1.1.1.0",
            ],
            mutates=False,
        )
        if sys_descr_res.rc != 0:
            return {"changed": False, "msg": "snmp unreachable", "data": {"discovery": []}}
        # Must be a "Fiber Service Platform F7" device.
        d = sys_descr_res.stdout.strip()
        if d.find("Fiber Service Platform F7") == -1:
            return {"changed": False, "msg": "not an ADVA FSP", "data": {"discovery": []}}

        # Walk the index column (name) to enumerate sensors.
        name_res = ctx.run(
            ["snmpwalk", "-v2c", "-c", community, "-Oqn", host, col_name],
            mutates=False,
        )
        if name_res.rc != 0 or name_res.stdout.strip() == "":
            return {
                "changed": False,
                "msg": "no temperature sensors found",
                "data": {"discovery": []},
            }

        sensors = {}
        for line in name_res.stdout.splitlines():
            sp = line.find(" ")
            if sp == -1:
                continue
            oid = line[:sp]
            name_val = line[sp + 1:]
            # Verify this is a known index under the column OID.
            if oid.find(col_name + ".") != 0:
                continue
            idx = oid[len(col_name) + 1:]
            if idx == "" or idx == oid:
                continue
            sensors[name_val] = {"index": idx}

        discovery = []
        for name_val in sensors.keys():
            info = sensors[name_val]
            t = ctx.run(
                [
                    "snmpget", "-v2c", "-c", community, "-Oqv",
                    host, col_temp + "." + info["index"],
                ],
                mutates=False,
            )
            h = ctx.run(
                [
                    "snmpget", "-v2c", "-c", community, "-Oqv",
                    host, col_high + "." + info["index"],
                ],
                mutates=False,
            )
            if t.rc != 0 or h.rc != 0:
                continue
            temp = _to_float(t.stdout)
            high = _to_float(h.stdout)
            if temp == None:
                continue
            # Mirror parse_adva_fsp_temp: only sensors reporting a real
            # temperature (raw_temp truthy + description truthy) and above
            # absolute-zero survive discovery.
            dres = ctx.run(
                [
                    "snmpget", "-v2c", "-c", community, "-Oqv",
                    host, col_desc + "." + info["index"],
                ],
                mutates=False,
            )
            desc = dres.stdout.strip() if dres.rc == 0 else ""
            if not desc or not t.stdout.strip():
                continue
            if temp > -273.0:
                discovery.append({
                    "item": name_val,
                    "params": {"warn": warn, "crit": crit},
                    "metrics": ["temperature"],
                })

        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    # --- CHECK MODE ---
    item = params.get("item", "")

    t = ctx.run(
        [
            "snmpget", "-v2c", "-c", community, "-Oqv",
            host, col_temp + "." + item,
        ],
        mutates=False,
    )
    if t.rc != 0:
        return {
            "changed": False,
            "msg": "no such sensor index: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    temp = _to_float(t.stdout)
    if temp == None:
        return {
            "changed": False,
            "msg": "invalid sensor data",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Device-defined thresholds (high/low), reported for context only.
    h = ctx.run(
        [
            "snmpget", "-v2c", "-c", community, "-Oqv",
            host, col_high + "." + item,
        ],
        mutates=False,
    )
    high = _to_float(h.stdout)
    l = ctx.run(
        [
            "snmpget", "-v2c", "-c", community, "-Oqv",
            host, col_low + "." + item,
        ],
        mutates=False,
    )
    low = _to_float(l.stdout)

    details = ""
    if high != None:
        details = details + "Device high: %f" % (high / 10.0)
    if low != None and low > -273:
        details = details + " Device low: %f" % (low / 10.0)

    state = _grade(temp / 10.0, warn, crit)

    return {
        "changed": False,
        "msg": "Temperature %f C" % (temp / 10.0),
        "data": {
            "state": state,
            "metrics": {"temperature": temp / 10.0},
            "details": details,
        },
    }