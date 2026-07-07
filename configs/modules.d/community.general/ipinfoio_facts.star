def main(ctx, params):
    http_agent = params.get("http_agent", "ansible-ipinfoio-module/0.0.1")
    timeout = str(params.get("timeout", 10))

    # Read-only probe: fetch IP geolocation data from ipinfo.io
    url = "https://ipinfo.io/json"
    headers = ["-H", "User-Agent:" + http_agent]
    res = ctx.run(
        ["curl", "-s", "-m", timeout] + headers + [url],
        mutates=False,
        ok_codes=[0],
    )

    if res.rc != 0:
        msg = "curl failed with rc=" + str(res.rc)
        if res.stderr != "":
            msg = msg + ": " + res.stderr
        fail(msg + "; check network connectivity and https://ipinfo.io/ availability")

    # Parse JSON response manually (no json module)
    data = _parse_ipinfo_json(res.stdout)

    # Set facts under ansible_facts
    facts = {}
    for key in data:
        facts["ip_" + key] = data[key]
    # Also include raw data under ansible_facts
    facts["ansible_facts"] = {"ipinfo": data}

    return {
        "changed": False,
        "msg": "Successfully retrieved IP geolocation facts",
        "data": {"ipinfo": data},
    }


def _parse_ipinfo_json(json_str):
    """Minimal JSON parser for flat ipinfo.io response."""
    s = json_str.strip()
    if len(s) == 0 or s[0] != '{' or s[len(s) - 1] != '}':
        fail("Invalid JSON: must start with { and end with }")

    inner = s[1:len(s) - 1].strip()
    if len(inner) == 0:
        return {}

    # Split top-level entries by commas outside quotes/brackets
    parts = []
    depth = 0
    current = ""
    in_string = False
    escape = False

    for i in range(len(inner)):
        ch = inner[i]
        if escape:
            current = current + ch
            escape = False
            continue
        if ch == '\\' and in_string:
            escape = True
            current = current + ch
            continue
        if ch == '"' and not escape:
            in_string = not in_string
            current = current + ch
            continue
        if not in_string:
            if ch == '{' or ch == '[':
                depth = depth + 1
            elif ch == '}' or ch == ']':
                depth = depth - 1
            elif ch == ',' and depth == 0:
                parts.append(current.strip())
                current = ""
                continue
        current = current + ch

    if len(current.strip()) > 0:
        parts.append(current.strip())

    result = {}
    for part in parts:
        if part.find(":") == -1:
            continue
        idx = part.find(":")
        key = part[0:idx].strip().strip('"')
        val_str = part[idx + 1:].strip()

        if val_str.startswith('"'):
            if not val_str.endswith('"') or len(val_str) < 2:
                fail("Invalid quoted string value")
            val = val_str[1:len(val_str) - 1]
            val = val.replace('\\"', '"')
        elif val_str.lower() == "null":
            val = None
        elif val_str.isdigit():
            val = int(val_str)
        elif val_str.startswith("-") and len(val_str) > 1 and val_str[1:].isdigit():
            val = int(val_str)
        elif _is_float(val_str):
            val = float(val_str)
        else:
            fail("Unsupported JSON value: " + val_str)

        result[key] = val

    return result


def _is_float(s):
    if s == "" or s[0] == '.' or s[len(s) - 1] == '.':
        return False
    dot_count = 0
    for i in range(len(s)):
        ch = s[i]
        if ch == '.':
            dot_count = dot_count + 1
            if dot_count > 1:
                return False
        elif not (ch >= '0' and ch <= '9'):
            return False
    return True
