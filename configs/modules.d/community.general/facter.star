def main(ctx, params):
    # Get facter binary path using run_command fallback
    facter_path = None
    # Try standard locations
    for path in ["facter", "/opt/puppetlabs/bin/facter"]:
        res = ctx.run([path, "--version"], mutates=False)
        if res.rc == 0:
            facter_path = path
            break
    if facter_path == None:
        fail("facter binary not found in standard locations")

    # Build command
    cmd = [facter_path, "--json"]
    args = params.get("arguments")
    if args != None:
        for arg in args:
            cmd.append(arg)

    # Run facter
    res = ctx.run(cmd, mutates=False)
    if res.rc != 0:
        fail("facter failed: " + res.stderr)
    
    # Parse JSON output using simple parsing since no json module
    facts = parse_json(res.stdout)
    
    return {"changed": False, "msg": "facter completed successfully", "data": facts}


def parse_json(s):
    """Simple JSON parser for flat dictionaries with string/number/bool/null values"""
    s = s.strip()
    if not s.startswith("{") or not s.endswith("}"):
        fail("invalid JSON: must be object")
    s = s[1:-1].strip()
    if not s:
        return {}
    
    result = {}
    depth = 0
    current_key = ""
    current_value = ""
    in_string = False
    escape = False
    i = 0
    
    while i < len(s):
        c = s[i]
        
        if escape:
            if in_string:
                if c == '"':
                    current_key += '"'
                elif c == '\\':
                    current_key += '\\'
                else:
                    current_key += c
            else:
                current_value += c
            escape = False
            i += 1
            continue
        
        if c == '\\':
            if in_string:
                escape = True
            else:
                current_value += c
            i += 1
            continue
        
        if c == '"':
            in_string = not in_string
            if in_string:
                if depth == 0:
                    current_key = ""
                else:
                    current_value = ""
            i += 1
            continue
        
        if not in_string:
            if c in "[{":
                depth += 1
            elif c in "]}":
                depth -= 1
            
            if depth == 0 and c == ':':
                key = current_key.strip()
                current_key = ""
                current_value = ""
            elif depth == 0 and c == ',':
                # Save completed key-value pair
                val = parse_value(current_value.strip())
                result[key] = val
                current_value = ""
            else:
                if depth == 0:
                    current_key += c
                else:
                    current_value += c
        else:
            current_key += c
        
        i += 1
    
    # Handle last pair
    if current_key != "":
        val = parse_value(current_value.strip())
        result[current_key.strip()] = val
    
    return result


def parse_value(v):
    """Parse a JSON value (string, number, bool, null)"""
    if v == "null":
        return None
    if v == "true":
        return True
    if v == "false":
        return False
    # Check for string
    if v.startswith('"') and v.endswith('"'):
        # Remove quotes and unescape
        s = v[1:-1]
        return s.replace('\\"', '"').replace('\\\\', '\\')
    # Try number
    if '.' in v:
        return float(v)
    return int(v)
