def main(ctx, params):
    user = params["user"]
    repo = params["repository"]
    github_url = params.get("github_url", "https://api.github.com")
    
    has_password = "password" in params
    has_token = "token" in params
    
    if not has_password and not has_token:
        fail("one of password or token is required")
    if has_password and has_token:
        fail("password and token are mutually exclusive")
    
    auth_header = ""
    if has_password:
        auth_str = user + ":" + params["password"]
        # Base64 encode manually
        b64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        padded_len = ((len(auth_str) + 2) // 3) * 3
        padded = auth_str + "\x00" * (padded_len - len(auth_str))
        b64_result = ""
        i = 0
        while i < len(padded):
            c1 = ord(padded[i]) if i < len(padded) else 0
            c2 = ord(padded[i + 1]) if i + 1 < len(padded) else 0
            c3 = ord(padded[i + 2]) if i + 2 < len(padded) else 0
            b64_result += b64_chars[(c1 >> 2) & 0x3F]
            b64_result += b64_chars[((c1 & 0x03) << 4) | ((c2 >> 4) & 0x0F)]
            b64_result += b64_chars[((c2 & 0x0F) << 2) | ((c3 >> 6) & 0x03)]
            b64_result += b64_chars[c3 & 0x3F]
            i += 3
        padding = len(auth_str) % 3
        if padding == 1:
            b64_result = b64_result[:-2] + "=="
        elif padding == 2:
            b64_result = b64_result[:-1] + "="
        auth_header = "Basic " + b64_result
    else:
        auth_header = "Token " + params["token"]
    
    url = github_url.rstrip("/") + "/repos/" + repo + "/hooks"
    headers_list = [
        "Authorization: " + auth_header,
        "Accept: application/vnd.github.v3+json",
    ]
    
    curl_cmd = [
        "curl", "-s", "-S", "-f", "-H", headers_list[0], "-H", headers_list[1],
        url
    ]
    
    res = ctx.run(curl_cmd, mutates=False)
    if res.skipped:
        return {"changed": False, "msg": "fetched hooks from " + repo}
    
    if res.rc != 0:
        fail("failed to fetch hooks: " + res.stderr)
    
    stdout = res.stdout
    if not stdout:
        fail("empty response from GitHub API")
    
    content = stdout.strip()
    if not (content.startswith("[") and content.endswith("]")):
        fail("unexpected response format: not a JSON array")
    
    content = content[1:-1].strip()
    if not content:
        hooks = []
    else:
        hooks = []
        depth = 0
        current = ""
        for char in content:
            if char == '{':
                depth += 1
                current += char
            elif char == '}':
                depth -= 1
                current += char
            elif char == ',' and depth == 0:
                if current.strip():
                    hooks.append(current.strip())
                current = ""
            else:
                current += char
        if current.strip():
            hooks.append(current.strip())
    
    processed_hooks = []
    for hook_str in hooks:
        hook = {}
        
        def extract_string(s, key):
            search = '"' + key + '":'
            idx = s.find(search)
            if idx == -1:
                return None
            start = idx + len(search)
            while start < len(s) and s[start] in " \t\n\r":
                start += 1
            if start >= len(s):
                return None
            if s[start] == '"':
                start += 1
                end = start
                while end < len(s) and s[end] != '"':
                    if s[end] == '\\' and end + 1 < len(s):
                        end += 2
                    else:
                        end += 1
                return s[start:end]
            elif s[start].isdigit() or s[start] == '-':
                end = start
                while end < len(s) and (s[end].isdigit() or s[end] == '.'):
                    end += 1
                return s[start:end]
            elif s[start:start+4] == 'true':
                return 'true'
            elif s[start:start+5] == 'false':
                return 'false'
            return None
        
        hook["id"] = extract_string(hook_str, "id")
        hook["url"] = extract_string(hook_str, "url")
        hook["active"] = extract_string(hook_str, "active")
        
        events_val = extract_string(hook_str, "events")
        if events_val != None:
            events_val = events_val.strip("[]")
            events = [e.strip().strip('"') for e in events_val.split(",") if e.strip()]
            hook["events"] = events
        else:
            hook["events"] = []
        
        config_start = hook_str.find('"config":{')
        has_secret = False
        if config_start != -1:
            depth = 1
            pos = config_start + len('"config":{')
            while pos < len(hook_str) and depth > 0:
                if hook_str[pos] == '{':
                    depth += 1
                elif hook_str[pos] == '}':
                    depth -= 1
                pos += 1
            config_str = hook_str[config_start + len('"config":{'):pos - 1]
            
            def get_config_field(config, key):
                search = '"' + key + '":'
                idx = config.find(search)
                if idx == -1:
                    return None
                start = idx + len(search)
                while start < len(config) and config[start] in " \t\n\r":
                    start += 1
                if start >= len(config):
                    return None
                if config[start] == '"':
                    start += 1
                    end = start
                    while end < len(config) and config[end] != '"':
                        if config[end] == '\\' and end + 1 < len(config):
                            end += 2
                        else:
                            end += 1
                    return config[start:end]
                elif config[start].isdigit() or config[start] == '-':
                    end = start
                    while end < len(config) and (config[end].isdigit() or config[end] == '.'):
                        end += 1
                    return config[start:end]
                return None
            
            hook["content_type"] = get_config_field(config_str, "content_type")
            hook["insecure_ssl"] = get_config_field(config_str, "insecure_ssl")
            hook["url"] = get_config_field(config_str, "url") or hook["url"]
            if config_str.find('"secret":') != -1:
                has_secret = True
        
        hook["has_shared_secret"] = has_secret
        
        last_resp_start = hook_str.find('"last_response":{')
        if last_resp_start != -1:
            depth = 1
            pos = last_resp_start + len('"last_response":{')
            while pos < len(hook_str) and depth > 0:
                if hook_str[pos] == '{':
                    depth += 1
                elif hook_str[pos] == '}':
                    depth -= 1
                pos += 1
            last_resp_str = hook_str[last_resp_start + len('"last_response":{'):pos - 1]
            
            def get_last_resp_field(field):
                search = '"' + field + '":'
                idx = last_resp_str.find(search)
                if idx == -1:
                    return None
                start = idx + len(search)
                while start < len(last_resp_str) and last_resp_str[start] in " \t\n\r":
                    start += 1
                if start >= len(last_resp_str):
                    return None
                if last_resp_str[start] == '"':
                    start += 1
                    end = start
                    while end < len(last_resp_str) and last_resp_str[end] != '"':
                        if last_resp_str[end] == '\\' and end + 1 < len(last_resp_str):
                            end += 2
                        else:
                            end += 1
                    return last_resp_str[start:end]
                elif last_resp_str[start].isdigit():
                    end = start
                    while end < len(last_resp_str) and last_resp_str[end].isdigit():
                        end += 1
                    return last_resp_str[start:end]
                return None
            
            hook["last_response"] = {}
            hook["last_response"]["status"] = get_last_resp_field("status")
            hook["last_response"]["message"] = get_last_resp_field("message")
            hook["last_response"]["code"] = get_last_resp_field("code")
        else:
            hook["last_response"] = {}
        
        processed_hooks.append(hook)
    
    return {"changed": False, "msg": "fetched hooks from " + repo, "data": {"hooks": processed_hooks}}
