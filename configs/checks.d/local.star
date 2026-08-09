# local check: cmk.plugins.checkmk.local
# Parses local check output lines like:
# 0 Service_FOO V=1 This Check is OK
# 1 Bar_Service - This is WARNING and has no performance data
# 2 NotGood V=120;50;100;0;1000 A critical check
# P Some_other_Service value1=10;30;50|value2=20;10:20;0:50;0;100 ...

# Map raw state strings to Checkmk State codes
STATE_MAP = {
    "0": 0,
    "1": 1,
    "2": 2,
    "3": 3,
    "P": 3,  # P maps to UNKNOWN (state=3) internally but apply_levels=True
}

def _try_float(s):
    # Strip trailing non-digit chars (like 'MB') then try float
    while s:
        # Check if remaining string can be converted
        # Simple check: all chars are digits, dot, plus, minus, e/E
        valid = True
        for c in s:
            if not (c.isdigit() or c in ".+-eE"):
                valid = False
                break
        if not valid:
            s = s[:-1]
            continue
        # Guard against empty or invalid strings
        if s == "" or s == "-" or s == "." or s == "+" or s == "inf" or s == "nan":
            s = s[:-1]
            continue
        # Try conversion with string methods only (no try/except)
        # If all validation passes, convert safely
        try_val = 0.0
        # Simple float parsing without exceptions
        digits = "0123456789"
        has_dot = False
        has_e = False
        pos = 0
        sign = 1
        if s[0] == '-':
            sign = -1
            pos = 1
        elif s[0] == '+':
            pos = 1
        if pos >= len(s):
            s = s[:-1]
            continue
        num_val = 0.0
        for c in s[pos:]:
            if c in digits:
                num_val = num_val * 10 + float(c)
            elif c == '.':
                if has_dot:
                    s = s[:-1]
                    continue
                has_dot = True
            elif c == 'e' or c == 'E':
                has_e = True
                break
            else:
                s = s[:-1]
                continue
        # Handle exponential notation separately (simplified)
        try_val = sign * num_val if not has_e else float(s)
        return try_val
    return 0.0

def _parse_levels(raw):
    # Parse perfdata levels string:
    # [WARN_LOWER:]WARN_UPPER;[CRIT_LOWER:]CRIT_UPPER;MIN;MAX
    # Returns (warn, crit, min, max) or None where appropriate
    if not raw:
        return None, None, None, None
    parts = raw.split(";")
    warn, crit, min_val, max_val = None, None, None, None
    # WARN part: optional lower:upper
    if len(parts) >= 1 and parts[0]:
        warn_parts = parts[0].split(":", 1)
        if len(warn_parts) == 2:
            warn = (_try_float(warn_parts[0]), _try_float(warn_parts[1]))
        else:
            warn = (_try_float(warn_parts[0]), float("inf"))
    # CRIT part
    if len(parts) >= 2 and parts[1]:
        crit_parts = parts[1].split(":", 1)
        if len(crit_parts) == 2:
            crit = (_try_float(crit_parts[0]), _try_float(crit_parts[1]))
        else:
            crit = (_try_float(crit_parts[0]), float("inf"))
    # MIN
    if len(parts) >= 4 and parts[3]:
        min_val = _try_float(parts[3])
    # MAX
    if len(parts) >= 5 and parts[4]:
        max_val = _try_float(parts[4])
    return warn, crit, min_val, max_val

def _parse_perfdata(perf_str):
    # Parse perfdata like "a=5;3:7;2:8;1;9" or "-"
    if perf_str == "-":
        return []
    items = []
    for entry in perf_str.split("|"):
        if "=" not in entry:
            continue
        name, rest = entry.split("=", 1)
        value = _try_float(rest.split(";")[0])
        # parse levels from remaining parts
        levels_upper = None
        levels_lower = None
        if len(rest.split(";")) >= 2:
            warn, crit, _, _ = _parse_levels(rest)
            if warn:
                levels_upper = (warn[0], warn[1])
            if crit:
                levels_lower = (crit[0], crit[1])
        items.append({"name": name, "value": value, "levels_upper": levels_upper, "levels_lower": levels_lower})
    return items

def _parse_line(line):
    # Parse a local check line
    # Returns (item, state, text, perfdata, apply_levels) or None
    line = line.strip()
    if not line:
        return None
    # Skip cache header: cached(1234,5678) ...
    if line.startswith("cached("):
        idx = line.find(") ")
        if idx != -1:
            line = line[idx+2:]
    # Split components
    # Regex: ^STATE ITEM PERFDATA TEXT$
    # Permissive: first token is state, last non-empty is text
    parts = line.split(None, 3)
    if len(parts) < 3:
        return None
    state_raw, item, perf_raw = parts[0], parts[1], parts[2]
    text = parts[3] if len(parts) > 3 else ""
    # Handle quoted item names (single/double)
    if (item.startswith('"') and item.endswith('"')) or (item.startswith("'") and item.endswith("'")):
        item = item[1:-1]
    # Convert state
    state_code = STATE_MAP.get(state_raw, 3)
    # apply_levels only for 'P'
    apply_levels = (state_raw == "P")
    # Parse perfdata
    perfdata = _parse_perfdata(perf_raw)
    # Return parsed data
    return (item, state_code, text, perfdata, apply_levels)

def _labelify(word):
    # Convert metric names to labels (Checkmk style)
    # e.g. "INCIDENTS_CT_PHISING" -> "Incidents ct phising"
    result = []
    prev_upper = False
    prev_digit = False
    for i, ch in enumerate(word):
        if ch.isupper():
            if prev_upper and i > 0 and word[i-1].isupper():
                result.append(" " + ch)
            else:
                result.append(ch)
            prev_upper = True
        elif ch.isdigit():
            if i > 0 and (not word[i-1].isdigit()):
                result.append(" " + ch)
            else:
                result.append(ch)
            prev_upper = False
        else:
            result.append(ch.lower())
            prev_upper = False
    return "".join(result)

def _format_metrics(perfdata, apply_levels):
    # Return list of metric strings for Checkmk
    items = []
    for p in perfdata:
        label = _labelify(p["name"])
        val = p["value"]
        parts = ["%s: %s" % (label, str(val))]
        if apply_levels:
            if p["levels_upper"]:
                parts.append("(warn/crit at %s/%s)" % (str(p["levels_upper"][0]), str(p["levels_upper"][1])))
            if p["levels_lower"]:
                parts.append("(warn/crit at %s/%s)" % (str(p["levels_lower"][0]), str(p["levels_lower"][1])))
        items.append(" ".join(parts))
    return "; ".join(items)

def main(ctx, params):
    # Discovery mode: enumerate services
    if params.get("_discover"):
        res = ctx.run(["cat", "/etc/checkmk/local"], mutates=False)
        lines = res.stdout.splitlines()
        items = []
        for line in lines:
            parsed = _parse_line(line)
            if parsed:
                item, _, _, _, _ = parsed
                items.append({"item": item, "params": {}, "metrics": ["perfdata"]})
        return {"changed": False, "msg": "discovered %d items" % len(items), "data": {"discovery": items}}
    # Check mode: evaluate one item
    item = params.get("item", "")
    res = ctx.run(["cat", "/etc/checkmk/local"], mutates=False)
    lines = res.stdout.splitlines()
    # Find matching line
    found = None
    for line in lines:
        parsed = _parse_line(line)
        if parsed and parsed[0] == item:
            found = parsed
            break
    if not found:
        return {"changed": False, "msg": "item not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    it, state_code, text, perfdata, apply_levels = found
    # Map state
    if state_code == 0:
        state = "OK"
    elif state_code == 1:
        state = "WARN"
    elif state_code == 2:
        state = "CRIT"
    else:
        state = "UNKNOWN"
    # Compute summary and details
    summary = text
    details = ""
    if text and "\n" in text:
        parts = text.split("\n", 1)
        summary = parts[0]
        details = parts[1]
    # Metrics
    metrics = {}
    metric_strs = []
    for p in perfdata:
        metrics[p["name"]] = p["value"]
        metric_strs.append("%s: %s" % (_labelify(p["name"]), str(p["value"])))
    metric_text = "; ".join(metric_strs)
    # Build message
    msg_parts = [summary]
    if metric_text:
        msg_parts.append(metric_text)
    msg = ". ".join(msg_parts) if msg_parts else ""
    if not msg:
        msg = summary
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": metrics, "details": details}}
