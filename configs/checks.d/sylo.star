def _parse_hint_row(line):
    f = line.split()
    if len(f) != 4:
        return None
    out = []
    for x in f:
        if not x.lstrip("-").isdigit():
            return None
        out.append(int(x))
    return out

def _probe_sylo_hint(ctx):
    path = "/var/cache/sylo/hint"
    st = ctx.stat(path)
    if st == None or not st.get("exists"):
        return None
    content = ctx.file_read(path)
    rows = []
    for line in content.splitlines():
        row = _parse_hint_row(line)
        if row == None:
            continue
        rows.append(row)
    if len(rows) < 3:
        return None
    mtime = int(st.get("mtime", 0))
    if len(rows) >= 4 and rows[0][0] > 0 and rows[0][0] < 2000000000:
        mtime = rows[0][0]
        in_off = rows[1][0]
        out_off = rows[2][0]
        size = rows[3][0]
    else:
        in_off = rows[0][0]
        out_off = rows[1][0]
        size = rows[2][0]
    return (mtime, in_off, out_off, size)

def main(ctx, params):
    if params.get("_discover"):
        data = _probe_sylo_hint(ctx)
        if data == None:
            return {
                "changed": False,
                "msg": "Sylo not installed",
                "data": {"discovery": []},
            }
        return {
            "changed": False,
            "msg": "discovered 1 item",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {
                            "max_age_secs": params.get("max_age_secs", 70),
                            "levels_usage_perc": params.get("levels_usage_perc", (5.0, 25.0)),
                        },
                        "metrics": ["in", "out", "used"],
                    }
                ],
                "service_labels": {"cmk/check_name": "sylo"},
            },
        }

    item = params.get("item", "")
    data = _probe_sylo_hint(ctx)
    if data == None:
        return {
            "changed": False,
            "msg": "No Sylo hint file found (sylo probably never ran on this system)",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    mtime, in_offset, out_offset, size = data

    if size <= 0:
        return {
            "changed": False,
            "msg": "Invalid Sylo hint file contents (non-positive size)",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }

    usage_levels = params.get("levels_usage_perc", (5.0, 25.0))
    usage_warn_perc = usage_levels[0]
    usage_crit_perc = usage_levels[1]
    max_age_secs = params.get("max_age_secs", 70)

    now_res = ctx.run(["date", "+%s"], mutates=False)
    now = int(now_res.stdout.strip())
    age = now - mtime
    if age > max_age_secs:
        return {
            "changed": False,
            "msg": "Sylo not running (Hintfile too old: last update %d secs ago)" % age,
            "data": {
                "state": "CRIT",
                "metrics": {"age": age},
                "details": "Hint file mtime: %d, age: %d secs, threshold: %d secs" % (mtime, age, max_age_secs),
            },
        }

    if in_offset == out_offset:
        bytesUsed = 0
    elif in_offset > out_offset:
        bytesUsed = in_offset - out_offset
    else:
        bytesUsed = size - out_offset + in_offset
    percUsed = float(bytesUsed) / size * 100
    used_mb = bytesUsed / (1024.0 * 1024.0)
    size_mb = size / (1024.0 * 1024.0)

    in_rate = 0.0
    out_rate = 0.0

    msg = "Silo is filled %fMB (%f%%), in %f B/s, out %f B/s" % (used_mb, percUsed, in_rate, out_rate)

    if percUsed >= usage_crit_perc:
        state = "CRIT"
    elif percUsed >= usage_warn_perc:
        state = "WARN"
    else:
        state = "OK"

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {
                "in": in_rate,
                "out": out_rate,
                "used": used_mb,
                "used_percent": percUsed,
                "age": age,
            },
            "details": "in_offset=%d out_offset=%d size=%d bytesUsed=%d percUsed=%f%% warn=%f%% crit=%f%%" % (
                in_offset, out_offset, size, bytesUsed, percUsed, usage_warn_perc, usage_crit_perc,
            ),
        },
    }