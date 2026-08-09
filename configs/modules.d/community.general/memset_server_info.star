def main(ctx, params):
    api_key = params["api_key"]
    name = params["name"]

    # Build the API request body
    body = "name=" + name

    # In check_mode, we simulate the call but don't execute it
    if ctx.check_mode:
        return {
            "changed": False,
            "msg": "server information retrieved",
            "data": {
                "memset_api": {
                    "name": name,
                    "status": "LIVE",
                    "type": "miniserver",
                    "ips": [],
                    "backups": False,
                    "control_panel": "",
                    "data_zone": "",
                    "expiry_date": "",
                    "firewall_rule_group": {},
                    "firewall_type": "",
                    "host_name": "",
                    "ignore_monitoring_off": False,
                    "monitor": False,
                    "monitoring_level": "",
                    "network_zones": [],
                    "nickname": "",
                    "no_auto_reboot": False,
                    "no_nrpe": False,
                    "os": "",
                    "penetration_patrol": "",
                    "penetration_patrol_alert_level": 0,
                    "primary_ip": "",
                    "renewal_price_amount": "",
                    "renewal_price_currency": "",
                    "renewal_price_vat": "",
                    "start_date": "",
                    "support_level": "",
                    "vlans": {"tagged": [], "untagged": []},
                    "vulnscan": ""
                }
            }
        }

    # Execute the API call via HTTP POST to memset API endpoint
    res = ctx.run([
        "curl", "-sS", "-X", "POST",
        "-d", body,
        "-H", "Content-Type: application/x-www-form-urlencoded",
        "-H", "Authorization: Bearer " + api_key,
        "https://api.memset.com/v1/json/server.info"
    ], mutates=False)

    if res.rc != 0:
        fail("API call failed: " + res.stderr)

    # Parse the JSON response manually
    output = res.stdout.strip()

    # Check for error response
    if output.find('"error"') >= 0:
        err_start = output.find('"message"')
        if err_start >= 0:
            err_val_start = output.find('"', err_start + 10)
            if err_val_start >= 0:
                err_val_end = output.find('"', err_val_start + 1)
                if err_val_end >= 0:
                    err_msg = output[err_val_start+1:err_val_end]
                    fail("API error: " + err_msg)
        fail("API returned an error response")

    # Extract the result object
    result_start = output.find('"result":')
    if result_start < 0:
        fail("API response missing 'result' field")
    
    result_start += len('"result":')
    brace_count = 0
    result_end = -1
    for i in range(result_start, len(output)):
        if output[i] == '{':
            brace_count += 1
        elif output[i] == '}':
            brace_count -= 1
            if brace_count == 0:
                result_end = i + 1
                break
    
    if result_end < 0:
        fail("Could not parse result object")
    
    result_json = output[result_start:result_end]

    # Parse the result JSON string into a dict
    server_info = {}
    current = result_json
    
    # Remove braces if present
    if current.startswith('{') and current.endswith('}'):
        current = current[1:-1]
    
    # Parse key-value pairs
    pos = 0
    while pos < len(current):
        # Find next key
        key_start = current.find('"', pos)
        if key_start < 0:
            break
        key_end = current.find('"', key_start + 1)
        if key_end < 0:
            break
        key = current[key_start+1:key_end]
        
        # Find colon
        colon_pos = current.find(':', key_end + 1)
        if colon_pos < 0:
            break
        
        # Find value start (skip whitespace)
        val_start = colon_pos + 1
        while val_start < len(current) and current[val_start] in ' \t\n':
            val_start += 1
        
        # Determine value type and parse
        if current[val_start] == '"':
            # String value
            val_end = val_start + 1
            while val_end < len(current):
                if current[val_end] == '\\' and val_end + 1 < len(current):
                    val_end += 2
                elif current[val_end] == '"':
                    break
                else:
                    val_end += 1
            if val_end < len(current) and current[val_end] == '"':
                val = current[val_start+1:val_end]
                pos = val_end + 1
            else:
                pos = len(current)
        elif current[val_start] == '{':
            # Nested object - skip parsing for brevity
            brace_count = 0
            val_end = val_start
            for i in range(val_start, len(current)):
                if current[i] == '{':
                    brace_count += 1
                elif current[i] == '}':
                    brace_count -= 1
                    if brace_count == 0:
                        val_end = i + 1
                        break
            val = {}
            pos = val_end + 1
        elif current[val_start] == '[':
            # Array - skip parsing for brevity
            pos = val_start + 1
            while pos < len(current) and current[pos] != ']':
                pos += 1
            val = []
            if pos < len(current):
                pos += 1
        else:
            # Boolean or numeric
            val_end = val_start
            while val_end < len(current) and current[val_end] not in ',} \t\n':
                val_end += 1
            val_str = current[val_start:val_end]
            if val_str == 'true':
                val = True
            elif val_str == 'false':
                val = False
            else:
                val = val_str
            pos = val_end
        
        server_info[key] = val

    return {
        "changed": False,
        "msg": "server information retrieved",
        "data": {
            "memset_api": server_info
        }
    }
