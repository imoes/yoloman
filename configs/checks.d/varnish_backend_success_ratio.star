# cmk/starcheck/varnish_backend_success_ratio.star
# Translated from Checkmk checkmk.varnish_backend_success_ratio
# READ-ONLY: never mutates, never ctx.file_write, always changed=False.

VAR_NAME = "varnish_backend_success_ratio"
DEFAULT_LEVELS_LOWER = (70.0, 60.0)  # (warn, crit) lower-is-better

def _read_varnishstat_json(ctx):
    res = ctx.run(["varnishstat", "-1", "-j"], mutates=False)
    if res.rc == 127:
        return None, "varnishstat binary not found"
    if res.rc != 0:
        return None, "varnishstat failed (rc=%d): %s" % (res.rc, res.stderr)
    if not res.stdout:
        return None, "varnishstat produced no output"
    # Guard: validate JSON before decoding
    s = res.stdout.strip()
    if not s:
        return None, "varnishstat produced empty output"
    # Starlark json.decode will fail() on bad input; we guard emptiness instead
    data = json.decode(s)
    return data, ""

def _section_from_json(data):
    section = {}
    if type(data) != "dict":
        return section
    candidates = []
    if "main" in data and type(data["main"]) == "dict":
        candidates.append(data["main"])
    if "mgt" in data and type(data["mgt"]) == "dict":
        candidates.append(data["mgt"])
    top_is_stats = False
    for v in data.values():
        if type(v) == "dict" and ("value" in v):
            top_is_stats = True
            break
    if top_is_stats:
        candidates.append(data)
    for block in candidates:
        for name, entry in block.items():
            if type(entry) == "dict" and "value" in entry:
                section[name] = entry
    return section

def _value_of(section, key):
    entry = section.get(key, {})
    if type(entry) == "dict" and "value" in entry:
        val = entry["value"]
        # Ensure numeric
        if type(val) == "int" or type(val) == "float":
            return val
        # Try to coerce
        s = str(val).strip()
        if s == "" or s == "None":
            return None
        # Attempt int then float
        if s.find(".") == -1 and _is_int(s):
            return int(s)
        if _is_float(s):
            return float(s)
        return None
    return None

def _is_int(s):
    if len(s) == 0:
        return False
    # Handle leading minus
    start = 0
    if s[0] == "-":
        start = 1
        if len(s) == 1:
            return False
    for i in range(start, len(s)):
        if s[i] < "0" or s[i] > "9":
            return False
    return True

def _is_float(s):
    if len(s) == 0:
        return False
    # Simple validator: digits, one dot, optional leading minus
    dot_seen = False
    start = 0
    if s[0] == "-":
        start = 1
        if len(s) == 1:
            return False
    digits_seen = False
    for i in range(start, len(s)):
        c = s[i]
        if c >= "0" and c <= "9":
            digits_seen = True
        elif c == ".":
            if dot_seen:
                return False
            dot_seen = True
        else:
            return False
    return digits_seen and (dot_seen or True)

def _has_key(section, key):
    return key in section

def main(ctx, params):
    if params.get("_discover"):
        data, err = _read_varnishstat_json(ctx)
        if data == None:
            return {"changed": False, "msg": "no varnishstat: %s" % err, "data": {"discovery": []}}
        section = _section_from_json(data)
        if _has_key(section, "backend_fail") and _has_key(section, "backend_conn"):
            return {
                "changed": False,
                "msg": "discovered Varnish Backend Success Ratio",
                "data": {
                    "discovery": [
                        {
                            "item": "",
                            "params": {"levels_lower": DEFAULT_LEVELS_LOWER},
                            "metrics": [VAR_NAME],
                        }
                    ],
                },
            }
        return {"changed": False, "msg": "varnish backend stats not present", "data": {"discovery": []}}

    item = params.get("item", "")
    if item != "":
        return {
            "changed": False,
            "msg": "unknown item: %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    data, err = _read_varnishstat_json(ctx)
    if data == None:
        return {
            "changed": False,
            "msg": "varnish not available: %s" % err,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }
    section = _section_from_json(data)

    if not _has_key(section, "backend_conn") or not _has_key(section, "backend_fail"):
        return {
            "changed": False,
            "msg": "backend success ratio counters not found",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    reference = _value_of(section, "backend_conn")
    additional = _value_of(section, "backend_fail")
    if reference == None or additional == None:
        return {
            "changed": False,
            "msg": "backend_conn or backend_fail value is missing",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    total = reference + additional
    ratio = 0.0
    if total > 0:
        ratio = 100.0 * reference / total

    levels_lower = params.get("levels_lower", DEFAULT_LEVELS_LOWER)
    warn = levels_lower[0] if len(levels_lower) >= 2 else DEFAULT_LEVELS_LOWER[0]
    crit = levels_lower[1] if len(levels_lower) >= 2 else DEFAULT_LEVELS_LOWER[1]

    state = "OK"
    if ratio <= crit:
        state = "CRIT"
    elif ratio <= warn:
        state = "WARN"

    return {
        "changed": False,
        "msg": "Backend success ratio %d%% (backend_conn=%d, backend_fail=%d)" % (int(ratio), reference, additional),
        "data": {
            "state": state,
            "metrics": {VAR_NAME: ratio},
            "details": "warn<=%d%%, crit<=%d%%, ratio=%d%%" % (warn, crit, int(ratio)),
        },
    }