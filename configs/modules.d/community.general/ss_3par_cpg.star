def main(ctx, params):
    cpg_name = params["cpg_name"]
    state = params["state"]
    storage_system_ip = params["storage_system_ip"]
    storage_system_username = params["storage_system_username"]
    storage_system_password = params["storage_system_password"]
    secure = params.get("secure", False)
    domain = params.get("domain")
    growth_increment = params.get("growth_increment")
    growth_limit = params.get("growth_limit")
    growth_warning = params.get("growth_warning")
    raid_type = params.get("raid_type")
    set_size = params.get("set_size")
    high_availability = params.get("high_availability")
    disk_type = params.get("disk_type")
    
    # Validate CPG name length
    if len(cpg_name) < 1 or len(cpg_name) > 31:
        fail("CPG name must be at least 1 character and not more than 31 characters")
    
    # Validate required parameters for creation
    if state == "present":
        if raid_type != None and set_size == None:
            fail("set_size is required when raid_type is specified")
        if set_size != None and raid_type == None:
            fail("raid_type is required when set_size is specified")
    
    # Build base URL
    protocol = "https" if secure else "http"
    base_url = protocol + "://%s:8080/api/v1" % storage_system_ip
    
    # Build auth JSON payload
    auth_payload = '{"user":"' + storage_system_username + '","password":"' + storage_system_password + '"}'
    
    auth_cmd = [
        "curl", "-sk", "-X", "POST",
        base_url + "/tokens",
        "-H", "Content-Type: application/json",
        "-d", auth_payload
    ]
    auth_res = ctx.run(auth_cmd)
    if auth_res.rc != 0:
        fail("Authentication failed: " + auth_res.stderr)
    
    # Parse token from response (simple extraction)
    token = ""
    lines = auth_res.stdout.splitlines()
    for line in lines:
        if '"token"' in line:
            parts = line.split('"token"')
            if len(parts) > 1:
                token_part = parts[1].strip()
                if token_part.startswith(":"):
                    token_part = token_part[1:].strip()
                if token_part.startswith('"'):
                    end_quote = token_part.find('"', 1)
                    if end_quote != -1:
                        token = token_part[1:end_quote]
                        break
    
    if token == "":
        fail("Failed to extract authentication token")
    
    headers = [
        "-H", "Content-Type: application/json",
        "-H", "Authorization: " + token
    ]
    
    # Check if CPG exists
    check_cmd = ["curl", "-sk"] + headers + ["-X", "GET", base_url + "/cpgs/" + cpg_name]
    check_res = ctx.run(check_cmd)
    cpg_exists = check_res.rc == 0
    
    if state == "present":
        if cpg_exists:
            return {"changed": False, "msg": "CPG %s already exists" % cpg_name}
        
        # Build the request body
        data = {"name": cpg_name}
        
        if domain != None:
            data["domain"] = domain
        
        optional = {}
        
        # Convert growth parameters to binary multiples (simplified)
        if growth_increment != None:
            val = growth_increment.strip()
            for suffix in [" TiB", " GiB", " MiB"]:
                if val.endswith(suffix):
                    num = val[:-len(suffix)].strip()
                    multiplier = 0
                    if suffix == " TiB":
                        multiplier = 1024 * 1024 * 1024
                    elif suffix == " GiB":
                        multiplier = 1024 * 1024
                    else:
                        multiplier = 1024
                    optional["growthIncrementMiB"] = int(float(num) * multiplier / 1024)
                    break
            if "growthIncrementMiB" not in optional:
                optional["growthIncrementMiB"] = int(val)
        
        if growth_limit != None:
            val = growth_limit.strip()
            for suffix in [" TiB", " GiB", " MiB"]:
                if val.endswith(suffix):
                    num = val[:-len(suffix)].strip()
                    multiplier = 0
                    if suffix == " TiB":
                        multiplier = 1024 * 1024 * 1024
                    elif suffix == " GiB":
                        multiplier = 1024 * 1024
                    else:
                        multiplier = 1024
                    optional["growthLimitMiB"] = int(float(num) * multiplier / 1024)
                    break
            if "growthLimitMiB" not in optional:
                optional["growthLimitMiB"] = int(val)
        
        if growth_warning != None:
            val = growth_warning.strip()
            for suffix in [" TiB", " GiB", " MiB"]:
                if val.endswith(suffix):
                    num = val[:-len(suffix)].strip()
                    multiplier = 0
                    if suffix == " TiB":
                        multiplier = 1024 * 1024 * 1024
                    elif suffix == " GiB":
                        multiplier = 1024 * 1024
                    else:
                        multiplier = 1024
                    optional["usedLDWarningAlertMiB"] = int(float(num) * multiplier / 1024)
                    break
            if "usedLDWarningAlertMiB" not in optional:
                optional["usedLDWarningAlertMiB"] = int(val)
        
        # Build LDLayout
        if raid_type != None:
            ld_layout = {}
            
            # Map RAID types
            raid_map = {"R0": 0, "R1": 1, "R5": 5, "R6": 6}
            if raid_type in raid_map:
                ld_layout["RAIDType"] = raid_map[raid_type]
            else:
                fail("Unsupported RAID type: " + raid_type)
            
            if set_size != None:
                ld_layout["setSize"] = set_size
            
            if high_availability != None:
                ha_map = {"PORT": 1, "CAGE": 2, "MAG": 3}
                if high_availability in ha_map:
                    ld_layout["HA"] = ha_map[high_availability]
                else:
                    fail("Unsupported high_availability: " + high_availability)
            
            if disk_type != None:
                disk_patterns = []
                disk_type_map = {"FC": 1, "NL": 2, "SSD": 3}
                if disk_type in disk_type_map:
                    disk_patterns.append({"diskType": disk_type_map[disk_type]})
                else:
                    fail("Unsupported disk_type: " + disk_type)
                ld_layout["diskPatterns"] = disk_patterns
            
            optional["LDLayout"] = ld_layout
        
        if len(optional) > 0:
            data["optional"] = optional
        
        # Serialize to JSON manually (simple escaping)
        def json_escape(s):
            return s.replace("\\", "\\\\").replace('"', '\\"')
        
        parts = []
        parts.append('{')
        parts.append('"name":"')
        parts.append(json_escape(cpg_name))
        parts.append('"')
        
        if domain != None:
            parts.append(',"domain":"')
            parts.append(json_escape(domain))
            parts.append('"')
        
        if len(optional) > 0:
            parts.append(',"optional":{')
            first = True
            for key in sorted(optional.keys()):
                if not first:
                    parts.append(",")
                first = False
                val = optional[key]
                if type(val) == "int":
                    parts.append('"')
                    parts.append(key)
                    parts.append('":')
                    parts.append(str(val))
                else:
                    parts.append('"')
                    parts.append(key)
                    parts.append('":')
                    if type(val) == "list":
                        parts.append('[')
                        for i in range(len(val)):
                            if i > 0:
                                parts.append(',')
                            item = val[i]
                            if type(item) == "dict":
                                inner = []
                                inner.append('{')
                                inner_first = True
                                for inner_key in sorted(item.keys()):
                                    if not inner_first:
                                        inner.append(',')
                                    inner_first = False
                                    inner_val = item[inner_key]
                                    inner.append('"')
                                    inner.append(inner_key)
                                    inner.append('":')
                                    inner.append(str(inner_val))
                                inner.append('}')
                                parts.append(''.join(inner))
                            else:
                                parts.append(str(inner_val))
                        parts.append(']')
                    else:
                        parts.append(str(val))
            parts.append('}')
        
        parts.append('}')
        data_str = ''.join(parts)
        
        if ctx.check_mode:
            return {"changed": True, "msg": "would create CPG %s" % cpg_name}
        
        create_cmd = ["curl", "-sk"] + headers + [
            "-X", "POST",
            base_url + "/cpgs",
            "-d", data_str
        ]
        create_res = ctx.run(create_cmd)
        
        if create_res.rc != 0:
            fail("Failed to create CPG: " + create_res.stderr)
        
        return {"changed": True, "msg": "Created CPG %s successfully." % cpg_name}
    
    elif state == "absent":
        if not cpg_exists:
            return {"changed": False, "msg": "CPG does not exist"}
        
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete CPG %s" % cpg_name}
        
        delete_cmd = ["curl", "-sk"] + headers + [
            "-X", "DELETE",
            base_url + "/cpgs/" + cpg_name
        ]
        delete_res = ctx.run(delete_cmd)
        
        if delete_res.rc != 0:
            fail("Failed to delete CPG: " + delete_res.stderr)
        
        return {"changed": True, "msg": "Deleted CPG %s successfully." % cpg_name}
    
    fail("Unsupported state: " + state)
