def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    if state != "absent":
        fail("state must be 'absent' for *_info modules")

    utm_host = params["utm_host"]
    utm_port = params.get("utm_port", 4444)
    utm_protocol = params.get("utm_protocol", "https")
    utm_token = params["utm_token"]
    validate_certs = params.get("validate_certs", True)

    url = "%s://%s:%s/api/objects/reverse_proxy/frontend/%s" % (
        utm_protocol, utm_host, utm_port, name
    )

    curl_args = [
        "curl", "-s", "-f", "-L", "-X", "GET",
        "-H", "X-Auth-Token:" + utm_token,
        url
    ]
    res = ctx.run(curl_args, mutates=False)
    if res.rc == 404:
        return {"changed": False, "msg": "frontend '%s' not found" % name, "data": None}
    if res.rc != 0:
        fail("failed to fetch frontend %s: %s" % (name, res.stderr))

    stdout = res.stdout.strip()
    if stdout == "":
        return {"changed": False, "msg": "frontend '%s' not found" % name, "data": None}

    # Parse JSON manually using recursive descent parser
    s = stdout
    i = [0]

    def skip_ws():
        while i[0] < len(s) and s[i[0]] in " \t\n\r":
            i[0] += 1

    def parse_value():
        skip_ws()
        c = s[i[0]]
        if c == '"':
            return parse_string()
        elif c == '{':
            return parse_object()
        elif c == '[':
            return parse_array()
        elif c == 't':
            if s[i[0]:i[0]+4] == "true":
                i[0] += 4
                return True
        elif c == 'f':
            if s[i[0]:i[0]+5] == "false":
                i[0] += 5
                return False
        elif c == 'n':
            if s[i[0]:i[0]+4] == "null":
                i[0] += 4
                return None
        elif c == '-' or (c >= '0' and c <= '9'):
            return parse_number()
        fail("unexpected char %s at position %d" % (c, i[0]))

    def parse_string():
        if s[i[0]] != '"':
            fail("expected string")
        i[0] += 1
        out = ""
        while i[0] < len(s):
            c = s[i[0]]
            if c == '"':
                i[0] += 1
                return out
            elif c == '\\':
                i[0] += 1
                if i[0] >= len(s):
                    fail("unterminated escape")
                esc = s[i[0]]
                if esc == '"':
                    out += '"'
                elif esc == '\\':
                    out += '\\'
                elif esc == 'b':
                    out += '\b'
                elif esc == 'f':
                    out += '\f'
                elif esc == 'n':
                    out += '\n'
                elif esc == 'r':
                    out += '\r'
                elif esc == 't':
                    out += '\t'
                else:
                    out += esc
                i[0] += 1
            else:
                out += c
                i[0] += 1
        fail("unterminated string")

    def parse_number():
        start = i[0]
        if s[i[0]] == '-':
            i[0] += 1
        while i[0] < len(s) and (s[i[0]] >= '0' and s[i[0]] <= '9' or s[i[0]] == '.'):
            i[0] += 1
        num_str = s[start:i[0]]
        if num_str.find('.') != -1:
            return float(num_str)
        return int(num_str)

    def parse_array():
        if s[i[0]] != '[':
            fail("expected array")
        i[0] += 1
        res = []
        skip_ws()
        if s[i[0]] == ']':
            i[0] += 1
            return res
        while True:
            res.append(parse_value())
            skip_ws()
            if s[i[0]] == ',':
                i[0] += 1
                skip_ws()
            elif s[i[0]] == ']':
                i[0] += 1
                break
            else:
                fail("expected comma or ] in array")
        return res

    def parse_object():
        if s[i[0]] != '{':
            fail("expected object")
        i[0] += 1
        res = {}
        skip_ws()
        if s[i[0]] == '}':
            i[0] += 1
            return res
        while True:
            skip_ws()
            if s[i[0]] != '"':
                fail("expected string key in object")
            key = parse_string()
            skip_ws()
            if s[i[0]] != ':':
                fail("expected : in object")
            i[0] += 1
            skip_ws()
            res[key] = parse_value()
            skip_ws()
            if s[i[0]] == ',':
                i[0] += 1
                skip_ws()
            elif s[i[0]] == '}':
                i[0] += 1
                break
            else:
                fail("expected , or } in object")
        return res

    result = parse_object()
    return {"changed": False, "msg": "frontend '%s' found" % name, "data": result}
