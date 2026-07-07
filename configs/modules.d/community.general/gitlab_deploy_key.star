def main(ctx, params):
    # Required parameters
    project = params["project"]
    key = params["key"]
    title = params["title"]
    
    # Optional parameters with defaults
    state = params.get("state", "present")
    can_push = params.get("can_push", False)
    api_url = params.get("api_url")
    validate_certs = params.get("validate_certs", True)
    
    # Authentication (only api_token supported in Starlark implementation)
    api_token = params.get("api_token")
    api_username = params.get("api_username")
    api_password = params.get("api_password")
    
    # Only api_token authentication is supported in this translation
    if api_token:
        auth_header = "PRIVATE-TOKEN: " + api_token
    elif api_username and api_password:
        auth_header = "Basic " + _basic_auth(api_username, api_password)
    else:
        fail("Authentication requires api_token, or api_username with api_password")
    
    # Build GitLab API URL
    base_url = api_url.rstrip("/") if api_url else "https://gitlab.com"
    
    # Get project ID
    res = ctx.run(
        ["curl", "-s", "-S", "-X", "GET", 
         base_url + "/api/v4/projects/" + _url_encode(project),
         "-H", "Authorization: " + auth_header,
         "-H", "Content-Type: application/json"],
        mutates=False
    )
    if res.rc != 0:
        fail("Failed to get project: " + res.stderr)
    
    projects = _parse_projects_response(res.stdout)
    if projects == None:
        fail("Project not found: " + project)
    project_id = projects.get("id")
    if project_id == None:
        fail("Project not found: " + project)
    
    # Find existing deploy key
    res = ctx.run(
        ["curl", "-s", "-S", "-X", "GET",
         base_url + "/api/v4/projects/" + str(project_id) + "/keys",
         "-H", "Authorization: " + auth_header,
         "-H", "Content-Type: application/json"],
        mutates=False
    )
    if res.rc != 0:
        fail("Failed to list deploy keys: " + res.stderr)
    
    keys = _parse_keys_list(res.stdout)
    
    existing_key = None
    i = 0
    while i < len(keys):
        k = keys[i]
        if isinstance(k, dict) and k.get("title") == title:
            existing_key = k
            break
        i = i + 1
    
    # Handle state
    if state == "absent":
        if existing_key != None:
            if ctx.check_mode:
                return {"changed": True, "msg": "Would delete deploy key " + title}
            res = ctx.run(
                ["curl", "-s", "-S", "-X", "DELETE",
                 base_url + "/api/v4/projects/" + str(project_id) + "/keys/" + str(existing_key["id"]),
                 "-H", "Authorization: " + auth_header,
                 "-H", "Content-Type: application/json"],
                mutates=True
            )
            if res.rc != 0:
                fail("Failed to delete deploy key: " + res.stderr)
            return {"changed": True, "msg": "Successfully deleted deploy key " + title}
        else:
            return {"changed": False, "msg": "Deploy key does not exist"}
    
    # state == "present"
    if existing_key != None:
        # Check if update needed (only can_push can be updated, key cannot)
        need_update = False
        if existing_key.get("can_push") != can_push:
            need_update = True
        
        if need_update:
            if ctx.check_mode:
                return {"changed": True, "msg": "Would update deploy key " + title}
            res = ctx.run(
                ["curl", "-s", "-S", "-X", "PUT",
                 base_url + "/api/v4/projects/" + str(project_id) + "/keys/" + str(existing_key["id"]),
                 "-H", "Authorization: " + auth_header,
                 "-H", "Content-Type: application/json",
                 "-d", '{"can_push": ' + ("true" if can_push else "false") + '}'],
                mutates=True
            )
            if res.rc != 0:
                fail("Failed to update deploy key: " + res.stderr)
            return {"changed": True, "msg": "Successfully updated deploy key " + title}
        else:
            return {"changed": False, "msg": "Deploy key already exists with correct settings"}
    else:
        # Create new deploy key
        if ctx.check_mode:
            return {"changed": True, "msg": "Would create deploy key " + title}
        res = ctx.run(
            ["curl", "-s", "-S", "-X", "POST",
             base_url + "/api/v4/projects/" + str(project_id) + "/keys",
             "-H", "Authorization: " + auth_header,
             "-H", "Content-Type: application/json",
             "-d", '{"title": "' + _escape_json(title) + '", "key": "' + _escape_json(key) + '", "can_push": ' + ("true" if can_push else "false") + '}'],
            mutates=True
        )
        if res.rc != 0:
            fail("Failed to create deploy key: " + res.stderr)
        return {"changed": True, "msg": "Successfully created deploy key " + title}


# Helper functions (no imports allowed - implemented manually)
def _basic_auth(username, password):
    # Simple base64 encoding (ASCII only)
    chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    input_str = username + ":" + password
    result = ""
    i = 0
    while i < len(input_str):
        # Get up to 3 bytes
        b1 = ord(input_str[i])
        b2 = 0
        b3 = 0
        if i + 1 < len(input_str):
            b2 = ord(input_str[i + 1])
        if i + 2 < len(input_str):
            b3 = ord(input_str[i + 2])
        
        # Encode 3 bytes as 4 base64 characters
        c1 = (b1 >> 2) & 63
        c2 = ((b1 & 3) << 4) | (b2 >> 4)
        c3 = ((b2 & 15) << 2) | (b3 >> 6)
        c4 = b3 & 63
        
        result = result + chars[c1] + chars[c2]
        
        if i + 1 < len(input_str):
            result = result + chars[c3]
        else:
            result = result + "="
        
        if i + 2 < len(input_str):
            result = result + chars[c4]
        else:
            result = result + "="
        
        i = i + 3
    
    return result


def _url_encode(s):
    # Simple URL encoding for common cases
    result = ""
    i = 0
    while i < len(s):
        c = s[i]
        if (c >= "0" and c <= "9") or (c >= "A" and c <= "Z") or (c >= "a" and c <= "z") or c == "-" or c == "_" or c == "." or c == "~":
            result = result + c
        elif c == " ":
            result = result + "%20"
        else:
            hex_val = ord(c)
            result = result + "%" + ("0" if hex_val < 16 else "") + format(hex_val, "X")
        i = i + 1
    return result


def _escape_json(s):
    # Simple JSON string escaping
    result = ""
    i = 0
    while i < len(s):
        c = s[i]
        if c == '"':
            result = result + '\\"'
        elif c == '\\':
            result = result + '\\\\'
        elif c == '\n':
            result = result + '\\n'
        elif c == '\r':
            result = result + '\\r'
        elif c == '\t':
            result = result + '\\t'
        else:
            result = result + c
        i = i + 1
    return result


def _parse_projects_response(s):
    # Simplified JSON parser for project objects
    s = s.strip()
    if s == "{}":
        return {}
    
    if not s.startswith("{"):
        return None
    
    return _parse_json_object(s)


def _parse_keys_list(s):
    # Simplified JSON parser for arrays
    s = s.strip()
    if s == "[]":
        return []
    
    if not s.startswith("["):
        return None
    
    return _parse_json_array(s[1:-1].strip())


def _parse_json_object(s):
    # Simplified object parser
    result = {}
    s = s.strip()
    if s == "{}":
        return result
    if not s.startswith("{"):
        return None
    s = s[1:-1].strip()
    if not s:
        return result
    
    # Tokenize key-value pairs (simplified, assumes valid JSON)
    items = []
    depth = 0
    current = ""
    in_string = False
    i = 0
    while i < len(s):
        c = s[i]
        if c == '"' and (not current or current[-1] != '\\'):
            in_string = not in_string
        if not in_string:
            if c == '{' or c == '[':
                depth = depth + 1
            elif c == '}' or c == ']':
                depth = depth - 1
            elif c == ',' and depth == 0:
                items.append(current.strip())
                current = ""
                i = i + 1
                continue
        current = current + c
        i = i + 1
    if current.strip():
        items.append(current.strip())
    
    i = 0
    while i < len(items):
        item = items[i]
        if ':' not in item:
            i = i + 1
            continue
        idx = item.find(':')
        key = item[:idx].strip().strip('"')
        value = item[idx + 1:].strip()
        
        if value.startswith('"'):
            # String value - extract content
            value = value[1:]
            end = 1
            while end < len(value) and (value[end] != '"' or value[end-1] == '\\'):
                end = end + 1
            value = value[:end].replace('\\"', '"').replace('\\\\', '\\')
        elif value == "true":
            value = True
        elif value == "false":
            value = False
        elif value.isdigit() or (value.startswith('-') and value[1:].isdigit()):
            value = int(value)
        
        result[key] = value
        i = i + 1
    
    return result


def _parse_json_array(s):
    # Simplified array parser
    items = []
    depth = 0
    current = ""
    in_string = False
    i = 0
    while i < len(s):
        c = s[i]
        if c == '"' and (not current or current[-1] != '\\'):
            in_string = not in_string
        if not in_string:
            if c == '{' or c == '[':
                depth = depth + 1
            elif c == '}' or c == ']':
                depth = depth - 1
            elif c == ',' and depth == 0:
                item = current.strip()
                if item:
                    if item.startswith('{'):
                        items.append(_parse_json_object(item))
                    else:
                        items.append(item)
                current = ""
                i = i + 1
                continue
        current = current + c
        i = i + 1
    if current.strip():
        item = current.strip()
        if item:
            if item.startswith('{'):
                items.append(_parse_json_object(item))
            else:
                items.append(item)
    
    return items
