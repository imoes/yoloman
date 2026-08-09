def main(ctx, params):
    cloud_init_path = "/var/lib/cloud/data"
    result_data = {}
    filter_opt = params.get("filter")

    for item in ["result", "status"]:
        if filter_opt == None or filter_opt == item:
            json_file = cloud_init_path + "/" + item + ".json"
            if ctx.file_exists(json_file):
                content = ctx.file_read(json_file)
                if content != "":
                    parsed = _parse_json(content)
                    result_data[item] = parsed
            else:
                result_data[item] = {}

    return {"changed": False, "msg": "Gathered cloud-init facts", "data": {"cloud_init_data_facts": result_data}}


def _parse_json(s):
    s = s.strip()
    if not s:
        fail("empty JSON content")
    if s[0] != '{':
        fail("expected JSON object, got '" + s[0] + "'")
    obj = {}
    s = _skip_ws(s[1:])
    if s and s[0] == '}':
        return obj
    while True:
        if s[0] != '"':
            fail("expected JSON string key, got '" + s[0] + "'")
        key, s = _parse_string(s[1:])
        s = _skip_ws(s)
        if not s or s[0] != ':':
            fail("expected ':' after key")
        s = _skip_ws(s[1:])
        if s[0] == '"':
            val, s = _parse_string(s[1:])
        elif s.startswith("true"):
            val, s = True, _skip_ws(s[4:])
        elif s.startswith("false"):
            val, s = False, _skip_ws(s[5:])
        elif s.startswith("null"):
            val, s = None, _skip_ws(s[4:])
        elif s[0] == '{':
            val, s = _parse_json(s)
        elif s[0] == '[':
            val, s = _parse_array(s)
        elif s[0] == '-' or s[0].isdigit():
            num_str = ""
            if s[0] == '-':
                num_str = "-"
                s = s[1:]
            while s and (s[0].isdigit() or s[0] == '.' or s[0] in "eE+-"):
                num_str = num_str + s[0]
                s = s[1:]
            if '.' in num_str or 'e' in num_str.lower():
                val = float(num_str)
            else:
                val = int(num_str)
            val, s = val, _skip_ws(s)
        else:
            fail("unexpected JSON value starting with '" + s[0] + "'")
        obj[key] = val
        s = _skip_ws(s)
        if not s:
            fail("unterminated JSON object")
        if s[0] == ',':
            s = _skip_ws(s[1:])
        elif s[0] == '}':
            return obj
        else:
            fail("expected ',' or '}', got '" + s[0] + "'")


def _parse_array(s):
    arr = []
    s = _skip_ws(s[1:])
    if s and s[0] == ']':
        return arr, _skip_ws(s[1:])
    while True:
        if s[0] == '"':
            val, s = _parse_string(s[1:])
        elif s.startswith("true"):
            val, s = True, _skip_ws(s[4:])
        elif s.startswith("false"):
            val, s = False, _skip_ws(s[5:])
        elif s.startswith("null"):
            val, s = None, _skip_ws(s[4:])
        elif s[0] == '{':
            val, s = _parse_json(s)
        elif s[0] == '[':
            val, s = _parse_array(s)
        elif s[0] == '-' or s[0].isdigit():
            num_str = ""
            if s[0] == '-':
                num_str = "-"
                s = s[1:]
            while s and (s[0].isdigit() or s[0] == '.' or s[0] in "eE+-"):
                num_str = num_str + s[0]
                s = s[1:]
            if '.' in num_str or 'e' in num_str.lower():
                val = float(num_str)
            else:
                val = int(num_str)
            val, s = val, _skip_ws(s)
        else:
            fail("unexpected array value starting with '" + s[0] + "'")
        arr.append(val)
        s = _skip_ws(s)
        if not s:
            fail("unterminated JSON array")
        if s[0] == ',':
            s = _skip_ws(s[1:])
        elif s[0] == ']':
            return arr, _skip_ws(s[1:])
        else:
            fail("expected ',' or ']', got '" + s[0] + "'")


def _parse_string(s):
    res = ""
    while s and s[0] != '"':
        if s[0] == '\\':
            if len(s) < 2:
                fail("incomplete escape sequence")
            escape = s[1]
            if escape == '"':
                res = res + '"'
            elif escape == '\\':
                res = res + '\\'
            elif escape == '/':
                res = res + '/'
            elif escape == 'b':
                res = res + '\b'
            elif escape == 'f':
                res = res + '\f'
            elif escape == 'n':
                res = res + '\n'
            elif escape == 'r':
                res = res + '\r'
            elif escape == 't':
                res = res + '\t'
            elif escape == 'u':
                if len(s) < 6:
                    fail("incomplete unicode escape")
                hex_str = s[2:6]
                code = int(hex_str, 16)
                res = res + unichr(code)
                s = s[6:]
                continue
            else:
                fail("invalid escape sequence: \\" + escape)
            s = s[2:]
        else:
            res = res + s[0]
            s = s[1:]
    if not s:
        fail("unterminated string")
    return res, s[1:]


def _skip_ws(s):
    while s and (s[0] == ' ' or s[0] == '\n' or s[0] == '\r' or s[0] == '\t'):
        s = s[1:]
    return s
