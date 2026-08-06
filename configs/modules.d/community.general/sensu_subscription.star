def main(ctx, params):
    name = params["name"]
    path = params.get("path", "/etc/sensu/conf.d/subscriptions.json")
    state = params.get("state", "present")
    backup = params.get("backup", False)

    # Probe current file content
    content = None
    if ctx.file_exists(path):
        content = ctx.file_read(path)
    else:
        content = ""

    # Parse JSON or fail on invalid JSON
    config = {}
    if content != "":
        config = _parse_json(content, path)

    reasons = []

    # Ensure 'client' key exists
    if "client" not in config:
        if state == "absent":
            reasons.append("`client' did not exist and state is `absent'")
            return {"changed": False, "msg": "OK", "reasons": reasons}
        config["client"] = {}
        reasons.append("`client' did not exist")

    # Ensure 'subscriptions' key exists
    if "subscriptions" not in config["client"]:
        if state == "absent":
            reasons.append("`client.subscriptions' did not exist and state is `absent'")
            return {"changed": False, "msg": "OK", "reasons": reasons}
        config["client"]["subscriptions"] = []
        reasons.append("`client.subscriptions' did not exist")

    subscriptions = config["client"]["subscriptions"]
    # Ensure subscriptions is a list
    if type(subscriptions) != "list":
        fail("expected subscriptions to be a list in " + path)

    # Check presence/absence of the subscription
    found = name in subscriptions

    if not found:
        if state == "absent":
            reasons.append("channel subscription was absent")
            return {"changed": False, "msg": "OK", "reasons": reasons}
        subscriptions.append(name)
        reasons.append("channel subscription was absent and state is `present'")
    else:
        if state == "absent":
            subscriptions.remove(name)
            reasons.append("channel subscription was present and state is `absent'")
        else:
            return {"changed": False, "msg": "OK", "reasons": reasons}

    # Compute new content
    new_content = _dump_json(config)
    if content == new_content and not backup:
        return {"changed": False, "msg": "OK", "reasons": reasons}

    # Backup if requested
    if backup and not ctx.check_mode:
        ts = str(int(ctx.run(["date", "+%s"]).stdout.strip()))
        backup_path = path + "." + ts + ".bak"
        ctx.file_write(backup_path, content)

    # Write new content
    if ctx.check_mode:
        return {"changed": True, "msg": "OK", "reasons": reasons}

    changed = ctx.file_write(path, new_content, mode="0644")
    return {"changed": changed, "msg": "OK", "reasons": reasons}


# Helper: simple JSON parser for Sensu subscriptions structure
def _parse_json(content, path):
    content = content.strip()
    if content == "":
        return {}

    content = content.replace("\n", "").replace("\r", "")
    i = [0]
    length = len(content)

    def skip_whitespace():
        while i[0] < length and content[i[0]] in " \t\n\r":
            i[0] += 1

    def expect_char(c):
        skip_whitespace()
        if i[0] >= length or content[i[0]] != c:
            fail("parse error at position %d in %s" % (i[0], path))
        i[0] += 1

    def parse_string():
        skip_whitespace()
        if content[i[0]] != '"':
            fail("parse error at position %d in %s" % (i[0], path))
        i[0] += 1
        s = ""
        while i[0] < length and content[i[0]] != '"':
            if content[i[0]] == '\\':
                i[0] += 1
                if i[0] < length:
                    esc = content[i[0]]
                    if esc == 'n':
                        s += '\n'
                    elif esc == 't':
                        s += '\t'
                    elif esc == 'r':
                        s += '\r'
                    elif esc == '"':
                        s += '"'
                    elif esc == '\\':
                        s += '\\'
                    i[0] += 1
            else:
                s += content[i[0]]
                i[0] += 1
        if i[0] >= length:
            fail("unterminated string in %s" % path)
        i[0] += 1
        return s

    def parse_value():
        skip_whitespace()
        if i[0] >= length:
            fail("unexpected end in %s" % path)
        if content[i[0]] == '"':
            return parse_string()
        elif content[i[0]] == '{':
            return parse_object()
        elif content[i[0]] == '[':
            return parse_array()
        elif content[i[0]:i[0]+4] == 'true':
            i[0] += 4
            return True
        elif content[i[0]:i[0]+5] == 'false':
            i[0] += 5
            return False
        elif content[i[0]:i[0]+4] == 'null':
            i[0] += 4
            return None
        else:
            start = i[0]
            if content[i[0]] == '-':
                i[0] += 1
            while i[0] < length and (content[i[0]].isdigit() or content[i[0]] == '.'):
                i[0] += 1
            val = content[start:i[0]]
            if '.' in val:
                return float(val)
            else:
                return int(val)

    def parse_array():
        arr = []
        expect_char('[')
        skip_whitespace()
        if content[i[0]] != ']':
            while True:
                arr.append(parse_value())
                skip_whitespace()
                if i[0] >= length:
                    fail("unterminated array in %s" % path)
                if content[i[0]] == ']':
                    i[0] += 1
                    break
                elif content[i[0]] == ',':
                    i[0] += 1
                else:
                    fail("expected ',' or ']' in array at position %d in %s" % (i[0], path))
        return arr

    def parse_object():
        obj = {}
        expect_char('{')
        skip_whitespace()
        if content[i[0]] != '}':
            while True:
                key = parse_string()
                skip_whitespace()
                if i[0] >= length or content[i[0]] != ':':
                    fail("expected ':' at position %d in %s" % (i[0], path))
                i[0] += 1
                obj[key] = parse_value()
                skip_whitespace()
                if i[0] >= length:
                    fail("unterminated object in %s" % path)
                if content[i[0]] == '}':
                    i[0] += 1
                    break
                elif content[i[0]] == ',':
                    i[0] += 1
                else:
                    fail("expected ',' or '}' in object at position %d in %s" % (i[0], path))
        return obj

    result = parse_object()
    return result


# Helper: simple JSON dumper for Sensu config structure
def _dump_json(obj):
    if obj == None:
        return "null"
    if type(obj) == "bool":
        return "true" if obj else "false"
    if type(obj) == "int" or type(obj) == "float":
        return str(obj)
    if type(obj) == "string":
        s = ""
        for c in obj:
            if c == '\\':
                s += "\\\\"
            elif c == '"':
                s += "\\\""
            elif c == '\n':
                s += "\\n"
            elif c == '\r':
                s += "\\r"
            elif c == '\t':
                s += "\\t"
            else:
                s += c
        return '"' + s + '"'
    if type(obj) == "list":
        items = [_dump_json(x) for x in obj]
        return "[" + ", ".join(items) + "]"
    if type(obj) == "dict":
        items = []
        for k in obj:
            items.append(_dump_json(k) + ": " + _dump_json(obj[k]))
        return "{" + ", ".join(items) + "}"
    fail("unsupported JSON type: " + str(type(obj)))
