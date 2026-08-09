def main(ctx, params):
    arguments = params.get("arguments", [])

    # Locate facter binary
    facter_path = None
    for candidate in ["facter", "/opt/puppetlabs/bin/facter"]:
        if ctx.file_exists(candidate):
            facter_path = candidate
            break
    if facter_path == None:
        fail("Could not find facter binary in PATH or /opt/puppetlabs/bin")

    # Build command
    cmd = [facter_path, "--json"] + arguments

    # Run facter in check_mode: probe only (no mutation)
    res = ctx.run(cmd, mutates=False)
    if res.skipped:
        # Should not happen for read-only command, but handle gracefully
        return {"changed": False, "msg": "facter not run in check_mode (skipped)"}

    if res.rc != 0:
        fail("facter command failed: " + res.stderr)

    # Parse JSON output manually (no json module available)
    facts = parse_json(res.stdout)

    return {"changed": False, "msg": "facter facts collected", "data": {"facter": facts}}


# Simple JSON parser for basic structures (objects, arrays, strings, numbers, booleans, null)
# Handles only what facter --json emits (no need for full compliance)
def parse_json(s):
    # Remove leading/trailing whitespace
    s = s.strip()
    if not s:
        fail("Empty JSON input")

    i = [0]  # mutable index

    def peek():
        while i[0] < len(s) and s[i[0]] in " \t\r\n":
            i[0] += 1
        if i[0] >= len(s):
            fail("Unexpected end of JSON")
        return s[i[0]]

    def advance():
        ch = peek()
        i[0] += 1
        return ch

    def skip_whitespace():
        while i[0] < len(s) and s[i[0]] in " \t\r\n":
            i[0] += 1

    def parse_value():
        skip_whitespace()
        ch = peek()
        if ch == '"':
            return parse_string()
        elif ch == '{':
            return parse_object()
        elif ch == '[':
            return parse_array()
        elif ch == 't':
            if s[i[0]:i[0]+4] == 'true':
                i[0] += 4
                return True
            fail("Invalid JSON")
        elif ch == 'f':
            if s[i[0]:i[0]+5] == 'false':
                i[0] += 5
                return False
            fail("Invalid JSON")
        elif ch == 'n':
            if s[i[0]:i[0]+4] == 'null':
                i[0] += 4
                return None
            fail("Invalid JSON")
        elif ch in '-0123456789':
            return parse_number()
        else:
            fail("Unexpected character in JSON: " + ch)

    def parse_string():
        if advance() != '"':
            fail("Expected string start")
        res = []
        while True:
            ch = advance()
            if ch == '"':
                return "".join(res)
            elif ch == '\\':
                next_ch = advance()
                if next_ch == '"':
                    res.append('"')
                elif next_ch == '\\':
                    res.append('\\')
                elif next_ch == 'b':
                    res.append('\b')
                elif next_ch == 'f':
                    res.append('\f')
                elif next_ch == 'n':
                    res.append('\n')
                elif next_ch == 'r':
                    res.append('\r')
                elif next_ch == 't':
                    res.append('\t')
                elif next_ch == 'u':
                    hex_digits = []
                    for _ in range(4):
                        c = advance()
                        if c not in '0123456789abcdefABCDEF':
                            fail("Invalid unicode escape")
                        hex_digits.append(c)
                    code_point = int("".join(hex_digits), 16)
                    res.append(unichr(code_point))
                else:
                    fail("Invalid escape sequence")
            else:
                res.append(ch)

    def parse_number():
        start = i[0]
        if peek() == '-':
            advance()
        while peek() in '0123456789':
            advance()
        if peek() == '.':
            advance()
            while peek() in '0123456789':
                advance()
        if peek() in 'eE':
            advance()
            if peek() in '+-':
                advance()
            while peek() in '0123456789':
                advance()
        s_num = s[start:i[0]]
        if '.' in s_num or 'e' in s_num or 'E' in s_num:
            return float(s_num)
        else:
            return int(s_num)

    def parse_object():
        if advance() != '{':
            fail("Expected object start")
        result = {}
        skip_whitespace()
        if peek() == '}':
            i[0] += 1
            return result
        while True:
            skip_whitespace()
            key = parse_string()
            skip_whitespace()
            if advance() != ':':
                fail("Expected ':' after key")
            value = parse_value()
            result[key] = value
            skip_whitespace()
            ch = advance()
            if ch == '}':
                return result
            elif ch != ',':
                fail("Expected ',' or '}' in object")

    def parse_array():
        if advance() != '[':
            fail("Expected array start")
        result = []
        skip_whitespace()
        if peek() == ']':
            i[0] += 1
            return result
        while True:
            value = parse_value()
            result.append(value)
            skip_whitespace()
            ch = advance()
            if ch == ']':
                return result
            elif ch != ',':
                fail("Expected ',' or ']' in array")

    # Handle top-level whitespace and dispatch
    return parse_value()
