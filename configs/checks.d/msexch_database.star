def _normalize_decimal_positional(value):
    if "," not in value:
        return value
    last_comma = value.rfind(",")
    last_dot = value.rfind(".")
    if last_dot > last_comma:
        out = ""
        for ch in value:
            if ch != ",":
                out += ch
        return out
    out = ""
    for ch in value:
        if ch != ".":
            out += ch
    return out.replace(",", ".")

def _normalize_by_locale(value, locale):
    if locale == None:
        return None
    loc = locale.lower()
    eu_prefixes = ["de-", "fr-", "it-", "es-", "nl-", "da-", "sv-", "no-", "fi-", "pt-"]
    en_prefixes = ["en-"]
    for p in eu_prefixes:
        if loc.startswith(p):
            out = ""
            for ch in value:
                if ch != ".":
                    out += ch
            return out.replace(",", ".")
    for p in en_prefixes:
        if loc.startswith(p):
            out = ""
            for ch in value:
                if ch != ",":
                    out += ch
            return out
    return None

def _normalize_decimal_fallback(value, locale):
    if not locale:
        return _normalize_decimal_positional(value)
    normalized = _normalize_by_locale(value, locale)
    if normalized != None:
        return normalized
    return _normalize_decimal_positional(value)

def _strip_quotes(s):
    s = s.strip()
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        return s[1:-1]
    return s

def _is_number(s):
    s = s.strip()
    if s == "":
        return False
    if s[0] == "-" or s[0] == "+":
        s = s[1:]
    if s == "":
        return False
    seen_dot = False
    has_digit = False
    for ch in s:
        if ch >= "0" and ch <= "9":
            has_digit = True
        elif ch == "." and not seen_dot:
            seen_dot = True
        else:
            return False
    return has_digit

def _to_float(s):
    s = s.strip()
    if s == "":
        return None
    neg = False
    if s[0] == "-" or s[0] == "+":
        if s[0] == "-":
            neg = True
        s = s[1:]
    if s == "":
        return None
    seen_dot = False
    has_digit = False
    intpart = ""
    fracpart = ""
    mode = "int"
    for ch in s:
        if ch >= "0" and ch <= "9":
            has_digit = True
            if mode == "int":
                intpart += ch
            else:
                fracpart += ch
        elif ch == "." and not seen_dot:
            seen_dot = True
            mode = "frac"
        elif ch in " \t":
            break
        else:
            return None
    if not has_digit:
        return None
    val = 0.0
    for ch in intpart:
        val = val * 10.0 + (ord(ch) - ord("0"))
    f = 0.0
    scale = 0.1
    for ch in fracpart:
        f = f + (ord(ch) - ord("0")) * scale
        scale = scale * 0.1
    val = val + f
    if neg:
        val = -val
    return val

def _normalize_decimal(value, decimal_separator):
    out = ""
    for ch in value:
        if ch >= "0" and ch <= "9":
            out += ch
        elif ch == decimal_separator:
            out += "."
        elif ch == "." and decimal_separator != ".":
            pass
    return out

def _extract_instance(obj):
    open_p = obj.find("(")
    close_p = obj.rfind(")")
    if open_p != -1 and close_p != -1 and close_p > open_p:
        return obj[open_p + 1:close_p]
    return obj

def _counter_to_var_lookup(counter):
    table = {
        "i/o database reads (attached) average latency": "read_attached_latency_s",
        "i/o database reads (recovery) average latency": "read_recovery_latency_s",
        "i/o database writes (attached) average latency": "write_latency_s",
        "i/o log writes average latency": "log_latency_s",
        "e/a: durchschnittliche wartezeit f\u00e4r datenbankleseoperationen (angef\u00e4gt)": "read_attached_latency_s",
        "e/a: durchschnittliche wartezeit f\u00e4r datenbankleseoperationen (wiederherstellung)": "read_recovery_latency_s",
        "e/a: durchschnittliche wartezeit f\u00e4r datenbankschreiboperationen (angef\u00e4gt)": "write_latency_s",
        "e/a: durchschnittliche wartezeit f\u00e4r protokollschreiboperationen": "log_latency_s",
    }
    return table.get(counter)

def _has_exchange(ctx):
    res = ctx.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", "Get-ExchangeServer"], mutates=False)
    return res.rc == 0 and res.stdout.strip() != ""

def _default_params():
    return {"read_attached_latency_s": (0.2, 0.25), "read_recovery_latency_s": (0.15, 0.2), "write_latency_s": (0.04, 0.05), "log_latency_s": (0.005, 0.01)}

def _fmt_ts(v):
    if v == None:
        return "n/a"
    ms = v * 1000.0
    return "%d ms" % int(ms)

def _gather_raw_rows(ctx):
    part1 = "Get-Counter -Counter '\\"
    part2 = "Process(*)(*)' -ErrorAction SilentlyContinue "
    part3 = "| Select-Object -ExpandProperty CounterSamples "
    part4 = "| ForEach-Object { $_.Path; $_.CookedValue }"
    cmd = part1 + "Process" + part2 + part3 + part4
    res = ctx.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", cmd], mutates=False)
    lines = res.stdout.split("\n")
    rows = []
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        i = i + 1
        if line == "":
            continue
        if line.startswith("\\\\"):
            val = ""
            if i < len(lines):
                nxt = lines[i].strip()
                if _is_number(nxt):
                    val = nxt
                    i = i + 1
            rows.append([line, val])
    return rows

def _parse_rows(rows):
    locale = None
    decimal_separator = None
    offset = 0
    end = 3
    if end > len(rows):
        end = len(rows)
    i = 0
    while i < end:
        row = rows[i]
        if len(row) >= 2:
            key = _strip_quotes(row[0])
            value = row[1].strip()
            if key == "locale":
                locale = value
                offset = i + 1
            elif key == "separator":
                decimal_separator = value
                offset = i + 1
            elif key == "Path":
                offset = i + 1
                break
        i = i + 1
    parsed = {}
    idx = offset
    while idx < len(rows):
        row = rows[idx]
        idx = idx + 1
        row = [_strip_quotes(r) for r in row]
        if len(row) != 2 or not row[0].startswith("\\\\"):
            continue
        parts = row[0].rsplit("\\", 2)
        if len(parts) != 3:
            continue
        __, obj, counter = parts
        var = _counter_to_var_lookup(counter.lower())
        if var == None:
            continue
        instance = _extract_instance(obj)
        value = row[1]
        if decimal_separator:
            value = _normalize_decimal(value, decimal_separator)
        else:
            value = _normalize_decimal_fallback(value, locale)
        if "/log verifier" in instance:
            sp = instance.rsplit(" ", 1)
            if len(sp) == 2:
                instance = sp[0]
        fval = _to_float(value)
        if fval == None:
            continue
        fval = fval / 1000.0
        inst = parsed.get(instance)
        if inst == None:
            inst = {}
            parsed[instance] = inst
        inst[var] = fval
    result = {}
    for item in parsed:
        values = parsed[item]
        if len(values) > 0:
            result[item] = values
    return result

def _grade(value, warn, crit):
    if value == None:
        return None
    if value >= crit:
        return "CRIT"
    if value >= warn:
        return "WARN"
    return "OK"

def _split_counter_path(path):
    parts = path.split("\\")
    if len(parts) < 2:
        return None
    obj = parts[2] if len(parts) > 2 else ""
    counter = parts[3] if len(parts) > 3 else ""
    return obj, counter

def _gather_raw_rows(ctx):
    cmd = "Get-Counter -Counter '\\" + "Process(*)(*)' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty CounterSamples | ForEach-Object { $_.Path; $_.CookedValue }"
    res = ctx.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", cmd], mutates=False)
    lines = res.stdout.split("\n")
    rows = []
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        i = i + 1
        if line == "":
            continue
        if line.startswith("\\\\"):
            val = ""
            if i < len(lines):
                nxt = lines[i].strip()
                if _is_number(nxt):
                    val = nxt
                    i = i + 1
            rows.append([line, val])
    return rows

def _gather_exchange_db_rows(ctx):
    cmd = "Get-ExchangeServer | Get-MailboxDatabase -Status | Get-Counter -ErrorAction SilentlyContinue | Select-Object -ExpandProperty CounterSamples | ForEach-Object { $_.Path; $_.CookedValue }"
    res = ctx.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", cmd], mutates=False)
    lines = res.stdout.split("\n")
    rows = []
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        i = i + 1
        if line == "":
            continue
        if line.startswith("\\\\"):
            val = ""
            if i < len(lines):
                nxt = lines[i].strip()
                if _is_number(nxt):
                    val = nxt
                    i = i + 1
            rows.append([line, val])
    return rows

def main(ctx, params):
    if params.get("_discover"):
        if not _has_exchange(ctx):
            return {"changed": False, "msg": "no Exchange server found", "data": {"discovery": []}}
        rows = _gather_exchange_db_rows(ctx)
        section = _parse_rows(rows)
        out = []
        for instance in section:
            pd = section[instance]
            metrics = []
            if pd.get("read_attached_latency_s") != None:
                metrics.append("db_read_latency_s")
            if pd.get("read_recovery_latency_s") != None:
                metrics.append("db_read_recovery_latency_s")
            if pd.get("write_latency_s") != None:
                metrics.append("db_write_latency_s")
            if pd.get("log_latency_s") != None:
                metrics.append("db_log_latency_s")
            out.append({"item": instance, "params": _default_params(), "metrics": metrics})
        return {"changed": False, "msg": "discovered %d databases" % len(out), "data": {"discovery": out}}
    item = params.get("item", "")
    rows = _gather_exchange_db_rows(ctx)
    section = _parse_rows(rows)
    if item not in section:
        return {"changed": False, "msg": "no such database: " + item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = section[item]
    dp = _default_params()
    ww = params.get("read_attached_latency_s", dp["read_attached_latency_s"])
    wr = params.get("read_recovery_latency_s", dp["read_recovery_latency_s"])
    wx = params.get("write_latency_s", dp["write_latency_s"])
    wl = params.get("log_latency_s", dp["log_latency_s"])
    states = []
    metrics = {}
    lines = []
    s = _grade(data.get("read_attached_latency_s"), ww[0], ww[1])
    states.append(s)
    if data.get("read_attached_latency_s") != None:
        metrics["db_read_latency_s"] = data["read_attached_latency_s"]
    lines.append("DB read (attached) latency: %s" % _fmt_ts(data.get("read_attached_latency_s")))
    s = _grade(data.get("read_recovery_latency_s"), wr[0], wr[1])
    states.append(s)
    if data.get("read_recovery_latency_s") != None:
        metrics["db_read_recovery_latency_s"] = data["read_recovery_latency_s"]
    lines.append("DB read (recovery) latency: %s" % _fmt_ts(data.get("read_recovery_latency_s")))
    s = _grade(data.get("write_latency_s"), wx[0], wx[1])
    states.append(s)
    if data.get("write_latency_s") != None:
        metrics["db_write_latency_s"] = data["write_latency_s"]
    lines.append("DB write (attached) latency: %s" % _fmt_ts(data.get("write_latency_s")))
    s = _grade(data.get("log_latency_s"), wl[0], wl[1])
    states.append(s)
    if data.get("log_latency_s") != None:
        metrics["db_log_latency_s"] = data["log_latency_s"]
    lines.append("Log latency: %s" % _fmt_ts(data.get("log_latency_s")))
    state = "OK"
    for st in states:
        if st == "CRIT":
            state = "CRIT"
            break
        if st == "WARN" and state == "OK":
            state = "WARN"
    msg = "Database %s: %s" % (item, "; ".join(lines))
    details = "\n".join(lines)
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": metrics, "details": details}}