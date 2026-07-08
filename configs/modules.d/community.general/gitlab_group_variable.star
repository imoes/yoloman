def _normalize_vars(params):
    # Convert 'vars' (dict) to 'variables' (list of dicts) if provided
    if params.get("vars"):
        vars_dict = params.get("vars")
        variables = []
        for k, v in vars_dict.items():
            if type(v) == "string" or type(v) == "int" or type(v) == "float":
                variables.append({
                    "name": k,
                    "value": str(v),
                    "masked": False,
                    "protected": False,
                    "raw": False,
                    "environment_scope": "*",
                    "variable_type": "env_var"
                })
            elif type(v) == "dict":
                var = {
                    "name": k,
                    "value": str(v.get("value", "")),
                    "masked": v.get("masked", False),
                    "protected": v.get("protected", False),
                    "raw": v.get("raw", False),
                    "environment_scope": v.get("environment_scope", "*"),
                    "variable_type": v.get("variable_type", "env_var")
                }
                variables.append(var)
            else:
                fail("vars value for key '%s' must be a string/number or dict" % k)
        return variables
    return params.get("variables", [])


def _normalize_variable(var):
    # Ensure default values and string conversion for all fields
    normalized = {}
    normalized["name"] = var.get("name")
    normalized["value"] = str(var.get("value", ""))
    normalized["masked"] = bool(var.get("masked", False))
    normalized["protected"] = bool(var.get("protected", False))
    normalized["raw"] = bool(var.get("raw", False))
    normalized["environment_scope"] = var.get("environment_scope", "*")
    normalized["variable_type"] = var.get("variable_type", "env_var")
    return normalized


def _normalize_existing(existing):
    # Convert raw existing variable dict to normalized form for comparison
    normalized = {}
    normalized["name"] = existing.get("key")
    normalized["value"] = existing.get("value")
    normalized["masked"] = bool(existing.get("masked", False))
    normalized["protected"] = bool(existing.get("protected", False))
    normalized["raw"] = bool(existing.get("raw", False))
    normalized["environment_scope"] = existing.get("environment_scope", "*")
    normalized["variable_type"] = existing.get("variable_type", "env_var")
    return normalized


def _get_group_path(params):
    group = params.get("group")
    # Strip trailing slashes if any
    return group.rstrip("/") if group else ""


def main(ctx, params):
    # Validate required parameters
    group = params.get("group")
    if group == None or group == "":
        fail("group is required")
    
    variables = _normalize_vars(params)
    state = params.get("state", "present")
    if state not in ["present", "absent"]:
        fail("state must be 'present' or 'absent'")
    
    purge = params.get("purge", False)
    
    # For state=present, all variables must have value
    if state == "present":
        for var in variables:
            if var.get("value") == None or var.get("value") == "":
                fail("value is required for all variables when state=present")
    
    # Normalize all input variables
    norm_requested = [_normalize_variable(v) for v in variables]
    
    # Build base URL and auth headers
    api_url = params.get("api_url", "").rstrip("/")
    if api_url == "":
        api_url = "https://gitlab.com"
    base_url = api_url + "/api/v4"
    
    headers = ["-H", "Content-Type: application/json"]
    if params.get("api_token"):
        headers.extend(["-H", "PRIVATE-TOKEN: " + params.get("api_token")])
    elif params.get("api_oauth_token"):
        headers.extend(["-H", "Authorization: Bearer " + params.get("api_oauth_token")])
    elif params.get("api_job_token"):
        headers.extend(["-H", "JOB-TOKEN: " + params.get("api_job_token")])
    else:
        fail("one of api_token, api_oauth_token, or api_job_token is required")
    
    # SSL options
    ssl_opts = []
    if not params.get("validate_certs", True):
        ssl_opts.append("--insecure")
    ca_path = params.get("ca_path")
    if ca_path:
        ssl_opts.extend(["--cacert", ca_path])
    
    # Find group ID by path
    group_path = _get_group_path(params)
    curl_args = ["curl", "-s", "-X", "GET"] + headers + ssl_opts + [base_url + "/groups/" + group_path]
    res = ctx.run(curl_args)
    if res.rc != 0:
        fail("failed to find group '%s': %s" % (group_path, res.stderr))
    
    group_data = res.stdout
    if group_data.startswith("{") == False:
        fail("failed to parse group info: invalid JSON")
    
    # Simple JSON parser for key "id"
    group_id = None
    lines = group_data.splitlines()
    for line in lines:
        stripped = line.strip()
        if stripped.startswith('"id"'):
            colon_pos = stripped.find(":")
            if colon_pos != -1:
                val_part = stripped[colon_pos+1:].strip()
                if val_part != "":
                    # Extract number
                    num_str = ""
                    for c in val_part:
                        if c.isdigit() or (c == '-' and num_str == ""):
                            num_str = num_str + c
                        else:
                            break
                    if num_str != "":
                        group_id = int(num_str)
    
    if group_id == None:
        fail("group '%s' not found" % group_path)
    
    # List existing variables
    curl_args = ["curl", "-s", "-X", "GET"] + headers + ssl_opts + [base_url + "/groups/" + str(group_id) + "/variables"]
    res = ctx.run(curl_args)
    if res.rc != 0:
        fail("failed to list group variables: %s" % res.stderr)
    
    existing_raw_data = res.stdout
    if existing_raw_data.startswith("[") == False:
        fail("failed to parse variables list: invalid JSON")
    
    # Parse list of variables manually
    # Remove outer brackets and split by },{ pattern
    content = existing_raw_data.strip()
    if len(content) > 0:
        content = content[1:-1].strip()  # remove [ and ]
    
    existing_raw = []
    if content != "":
        # Split by },{ to get individual objects
        # Replace },{ with a delimiter
        temp = content.replace("},{", "|||OBJ|||")
        objs = temp.split("|||OBJ|||")
        for obj in objs:
            obj = obj.strip()
            if obj == "":
                continue
            # Extract key
            key_val = ""
            key_start = obj.find('"key"')
            if key_start != -1:
                key_start = obj.find(':', key_start)
                if key_start != -1:
                    end = obj.find(',', key_start)
                    if end == -1:
                        end = obj.find('}', key_start)
                    key_val = obj[key_start+1:end].strip()
            # Extract value
            value_val = ""
            val_start = obj.find('"value"')
            if val_start != -1:
                val_start = obj.find(':', val_start)
                if val_start != -1:
                    # Find end of string value (next unescaped ")
                    end = val_start + 1
                    while end < len(obj):
                        if obj[end] == '"' and (end == 0 or obj[end-1] != '\\'):
                            break
                        end += 1
                    value_val = obj[val_start+1:end].strip()
                    if value_val.startswith('"') and value_val.endswith('"'):
                        value_val = value_val[1:-1]
            # Extract environment_scope
            env_scope = "*"
            env_start = obj.find('"environment_scope"')
            if env_start != -1:
                env_start = obj.find(':', env_start)
                if env_start != -1:
                    end = obj.find(',', env_start)
                    if end == -1:
                        end = obj.find('}', env_start)
                    env_val = obj[env_start+1:end].strip()
                    if env_val.startswith('"') and env_val.endswith('"'):
                        env_val = env_val[1:-1]
                    env_scope = env_val
            # Extract masked
            masked_val = "false"
            masked_start = obj.find('"masked"')
            if masked_start != -1:
                masked_start = obj.find(':', masked_start)
                if masked_start != -1:
                    end = obj.find(',', masked_start)
                    if end == -1:
                        end = obj.find('}', masked_start)
                    masked_val = obj[masked_start+1:end].strip().lower()
            # Extract protected
            protected_val = "false"
            prot_start = obj.find('"protected"')
            if prot_start != -1:
                prot_start = obj.find(':', prot_start)
                if prot_start != -1:
                    end = obj.find(',', prot_start)
                    if end == -1:
                        end = obj.find('}', prot_start)
                    protected_val = obj[prot_start+1:end].strip().lower()
            # Extract raw
            raw_val = "false"
            raw_start = obj.find('"raw"')
            if raw_start != -1:
                raw_start = obj.find(':', raw_start)
                if raw_start != -1:
                    end = obj.find(',', raw_start)
                    if end == -1:
                        end = obj.find('}', raw_start)
                    raw_val = obj[raw_start+1:end].strip().lower()
            # Extract variable_type
            vtype = "env_var"
            type_start = obj.find('"variable_type"')
            if type_start != -1:
                type_start = obj.find(':', type_start)
                if type_start != -1:
                    end = obj.find(',', type_start)
                    if end == -1:
                        end = obj.find('}', type_start)
                    vtype = obj[type_start+1:end].strip()
                    if vtype.startswith('"') and vtype.endswith('"'):
                        vtype = vtype[1:-1]
            
            existing_raw.append({
                "key": key_val,
                "value": value_val,
                "environment_scope": env_scope,
                "masked": masked_val == "true",
                "protected": protected_val == "true",
                "raw": raw_val == "true",
                "variable_type": vtype
            })
    
    existing = [_normalize_existing(v) for v in existing_raw]
    
    # Prepare result lists
    added = []
    updated = []
    removed = []
    untouched = []
    
    # Check mode: simulate change
    if ctx.check_mode:
        for var in norm_requested:
            found = False
            for ex in existing:
                if ex.get("name") == var.get("name") and ex.get("environment_scope") == var.get("environment_scope"):
                    found = True
                    if ex != var:
                        updated.append(var.get("name"))
                    else:
                        untouched.append(var.get("name"))
                    break
            if not found:
                added.append(var.get("name"))
        
        if state == "absent":
            for var in norm_requested:
                found = False
                for ex in existing:
                    if ex.get("name") == var.get("name") and ex.get("environment_scope") == var.get("environment_scope"):
                        found = True
                        break
                if found:
                    removed.append(var.get("name"))
            if not purge:
                # Only remove requested ones
                pass
            else:
                # Remove all
                for ex in existing:
                    if ex.get("name") not in [v.get("name") for v in norm_requested]:
                        removed.append(ex.get("name"))
        elif state == "present" and purge:
            for ex in existing:
                found = False
                for var in norm_requested:
                    if ex.get("name") == var.get("name") and ex.get("environment_scope") == var.get("environment_scope"):
                        found = True
                        break
                if not found:
                    removed.append(ex.get("name"))
        
        changed = len(added) > 0 or len(updated) > 0 or len(removed) > 0
        return {
            "changed": changed,
            "msg": "would update variables" if changed else "variables are in desired state",
            "group_variable": {
                "added": added,
                "updated": updated,
                "removed": removed,
                "untouched": untouched
            }
        }
    
    # Real mode: perform changes
    
    # Process state=present: create/update
    if state == "present":
        for var in norm_requested:
            # Check if exists with same environment_scope
            found = None
            for ex in existing:
                if ex.get("name") == var.get("name") and ex.get("environment_scope") == var.get("environment_scope"):
                    found = ex
                    break
            
            if found == None:
                # Create
                escaped_name = var.get("name").replace('"', '\\"')
                escaped_value = var.get("value").replace('"', '\\"').replace('\\', '\\\\')
                payload = '{"key":"%s","value":"%s","masked":%s,"protected":%s,"raw":%s,"variable_type":"%s","environment_scope":"%s"}' % (
                    escaped_name,
                    escaped_value,
                    "true" if var.get("masked") else "false",
                    "true" if var.get("protected") else "false",
                    "true" if var.get("raw") else "false",
                    var.get("variable_type"),
                    var.get("environment_scope").replace('"', '\\"')
                )
                curl_args = ["curl", "-s", "-X", "POST"] + headers + ssl_opts + ["-d", payload, base_url + "/groups/" + str(group_id) + "/variables"]
                res = ctx.run(curl_args)
                if res.rc != 0:
                    fail("failed to create variable %s: %s" % (var.get("name"), res.stderr))
                added.append(var.get("name"))
            else:
                # Update if changed
                if ex != var:
                    escaped_value = var.get("value").replace('"', '\\"').replace('\\', '\\\\')
                    payload = '{"value":"%s","masked":%s,"protected":%s,"raw":%s,"variable_type":"%s","environment_scope":"%s"}' % (
                        escaped_value,
                        "true" if var.get("masked") else "false",
                        "true" if var.get("protected") else "false",
                        "true" if var.get("raw") else "false",
                        var.get("variable_type"),
                        var.get("environment_scope").replace('"', '\\"')
                    )
                    curl_args = ["curl", "-s", "-X", "PUT"] + headers + ssl_opts + ["-d", payload, base_url + "/groups/" + str(group_id) + "/variables/" + var.get("name") + "?environment_scope=" + var.get("environment_scope")]
                    res = ctx.run(curl_args)
                    if res.rc != 0:
                        fail("failed to update variable %s: %s" % (var.get("name"), res.stderr))
                    updated.append(var.get("name"))
                else:
                    untouched.append(var.get("name"))
        
        # Handle purge: delete extras
        if purge:
            for ex in existing:
                found = False
                for var in norm_requested:
                    if ex.get("name") == var.get("name") and ex.get("environment_scope") == var.get("environment_scope"):
                        found = True
                        break
                if not found:
                    curl_args = ["curl", "-s", "-X", "DELETE"] + headers + ssl_opts + [base_url + "/groups/" + str(group_id) + "/variables/" + ex.get("name") + "?environment_scope=" + ex.get("environment_scope")]
                    res = ctx.run(curl_args)
                    if res.rc != 0:
                        fail("failed to delete variable %s: %s" % (ex.get("name"), res.stderr))
                    removed.append(ex.get("name"))
    
    # Process state=absent
    elif state == "absent":
        if purge:
            # Delete all
            for ex in existing:
                curl_args = ["curl", "-s", "-X", "DELETE"] + headers + ssl_opts + [base_url + "/groups/" + str(group_id) + "/variables/" + ex.get("name") + "?environment_scope=" + ex.get("environment_scope")]
                res = ctx.run(curl_args)
                if res.rc != 0:
                    fail("failed to delete variable %s: %s" % (ex.get("name"), res.stderr))
                removed.append(ex.get("name"))
        else:
            # Delete only requested ones
            for var in norm_requested:
                found = None
                for ex in existing:
                    if ex.get("name") == var.get("name") and ex.get("environment_scope") == var.get("environment_scope"):
                        found = ex
                        break
                if found != None:
                    curl_args = ["curl", "-s", "-X", "DELETE"] + headers + ssl_opts + [base_url + "/groups/" + str(group_id) + "/variables/" + var.get("name") + "?environment_scope=" + var.get("environment_scope")]
                    res = ctx.run(curl_args)
                    if res.rc != 0:
                        fail("failed to delete variable %s: %s" % (var.get("name"), res.stderr))
                    removed.append(var.get("name"))
    
    changed = len(added) > 0 or len(updated) > 0 or len(removed) > 0
    msg = "updated variables" if changed else "variables are in desired state"
    return {
        "changed": changed,
        "msg": msg,
        "group_variable": {
            "added": added,
            "updated": updated,
            "removed": removed,
            "untouched": untouched
        }
    }
