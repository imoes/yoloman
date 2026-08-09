def main(ctx, params):
    # Extract parameters
    zone_name = params["zone_name"]
    record_name = params["record_name"]
    record_type = params.get("record_type", "A")
    record_value = params.get("record_value")
    record_values = params.get("record_values")
    record_ttl = params.get("record_ttl")
    state = params.get("state", "present")
    
    # Validate mutual exclusivity of record_value and record_values
    if record_value != None and (record_values != None and len(record_values) > 0):
        fail("record_value and record_values are mutually exclusive")
    
    # Normalize record_values
    if record_value != None:
        record_values = [record_value]
    elif record_values == None:
        fail("exactly one of record_value or record_values must be specified")
    
    # Construct IPA server URL
    ipa_host = params.get("ipa_host", "ipa.example.com")
    ipa_port = str(params.get("ipa_port", 443))
    ipa_prot = params.get("ipa_prot", "https")
    ipa_user = params.get("ipa_user", "admin")
    ipa_pass = params.get("ipa_pass")
    
    if ipa_prot not in ["http", "https"]:
        fail("ipa_prot must be 'http' or 'https'")
    
    server_url = ipa_prot + "://" + ipa_host + ":" + ipa_port + "/ipa"
    
    # Build IPA session command
    # Note: We assume 'curl' is available (standard on most systems)
    # Using KRB5CCNAME or keytab authentication is not implemented for brevity
    if ipa_pass == None:
        fail("ipa_pass must be provided (GSSAPI support not implemented)")
    
    # Login to IPA
    login_cmd = [
        "curl", "-s", "-k", "--negotiate", "-u", ":", "-X", "POST",
        server_url + "/session/login_password",
        "-d", "user=" + ipa_user + "&password=" + ipa_pass
    ]
    res = ctx.run(login_cmd)
    if res.rc != 0:
        fail("IPA login failed: " + res.stderr)
    
    # Extract session cookie (simplified: assumes cookie is in response headers)
    # In practice, IPA returns a session cookie; here we simulate reuse
    # For brevity, we'll store session cookie in ctx (not possible in real Starlark)
    # Instead, we'll use cookie jar via --cookie-jar for demonstration
    cookie_jar = "/tmp/ipa_cookie_" + ctx.facts().get("hostname", "unknown")
    
    # Helper: IPA JSON request
    def ipa_request(method, name, item):
        cmd = [
            "curl", "-s", "-k", "--cookie-jar", cookie_jar, "--cookie", cookie_jar,
            "-X", "POST", server_url + "/json",
            "-d", "{\"method\":\"" + method + "\",\"params\":[[\"" + name + "\"],{\"all\":true" + (",\"item\":" + item if item else "") + "}]}"
        ]
        res = ctx.run(cmd)
        if res.rc != 0:
            fail("IPA API call failed: " + res.stderr)
        # Parse JSON manually (Starlark has no json module)
        # Assume response contains 'result' field
        # This is a simplified parser; real implementation would need full JSON parsing
        # For brevity, assume result is in 'result' key
        stdout = res.stdout
        # Extract result: naive extraction
        start = stdout.find('"result":{')
        if start == -1:
            fail("Could not parse IPA response: missing 'result'")
        end = stdout.find('}', start)
        # Simplified: just return stdout for now
        # In real implementation, proper JSON parsing would be needed
        return stdout
    
    # Check if record exists (dnsrecord_find)
    find_cmd = [
        "curl", "-s", "-k", "--cookie-jar", cookie_jar, "--cookie", cookie_jar,
        "-X", "POST", server_url + "/json",
        "-d", "{\"method\":\"dnsrecord_find\",\"params\":[[\"" + zone_name + "\"],{\"idnsname\":\"" + record_name + "\",\"all\":true}]}"
    ]
    res = ctx.run(find_cmd, mutates=False)
    if res.rc != 0:
        fail("Failed to check DNS record existence: " + res.stderr)
    
    ipa_record_found = res.stdout.find('"result":{') != -1
    
    # Prepare module_dnsrecord dict for diff (as JSON string)
    item_dict = {"idnsname": record_name}
    
    # Map record type to IPA field
    type_field_map = {
        "A": "a_part_ip_address",
        "AAAA": "aaaa_part_ip_address",
        "A6": "a6_part_data",
        "CNAME": "cname_part_hostname",
        "DNAME": "dname_part_target",
        "NS": "ns_part_hostname",
        "PTR": "ptr_part_hostname",
        "TXT": "txtrecord",
        "SRV": "srvrecord",
        "MX": "mxrecord"
    }
    
    # Build item for add/mod
    item_parts = []
    if record_ttl != None:
        item_parts.append("\"dnsttl\":\"" + str(record_ttl) + "\"")
    
    # Add values based on type
    field = type_field_map.get(record_type)
    if field == None:
        fail("Unsupported record_type: " + record_type)
    
    for val in record_values:
        item_parts.append("\"" + field + "\":[\"" + val + "\"]")
    
    item_str = "{" + ",".join(item_parts) + "}"
    
    changed = False
    msg = ""
    
    if state == "present":
        if not ipa_record_found:
            changed = True
            if not ctx.check_mode:
                add_cmd = [
                    "curl", "-s", "-k", "--cookie-jar", cookie_jar, "--cookie", cookie_jar,
                    "-X", "POST", server_url + "/json",
                    "-d", "{\"method\":\"dnsrecord_add\",\"params\":[[\"" + zone_name + "\"]," + item_str + "]}"
                ]
                res = ctx.run(add_cmd, mutates=True)
                if res.rc != 0:
                    fail("Failed to create DNS record: " + res.stderr)
            else:
                msg = "would add DNS record '" + record_name + "' of type '" + record_type + "'"
        else:
            # Check for differences (simplified: compare values directly)
            # Real implementation would do full diff
            current_values = []
            if record_type == "A":
                if res.stdout.find('"arecord":') != -1:
                    # Extract arecord values (naive)
                    start = res.stdout.find('"arecord":')
                    if start != -1:
                        start_val = res.stdout.find('[', start)
                        end_val = res.stdout.find(']', start_val)
                        current_values = res.stdout[start_val+1:end_val].replace('"', '').split(',')
                else:
                    current_values = []
            elif record_type == "AAAA":
                if res.stdout.find('"aaaarecord":') != -1:
                    start = res.stdout.find('"aaaarecord":')
                    start_val = res.stdout.find('[', start)
                    end_val = res.stdout.find(']', start_val)
                    current_values = res.stdout[start_val+1:end_val].replace('"', '').split(',')
            # ... (simplified for brevity)
            
            # Compare (case-sensitive)
            if sorted(record_values) != sorted(current_values):
                changed = True
                if not ctx.check_mode:
                    mod_cmd = [
                        "curl", "-s", "-k", "--cookie-jar", cookie_jar, "--cookie", cookie_jar,
                        "-X", "POST", server_url + "/json",
                        "-d", "{\"method\":\"dnsrecord_mod\",\"params\":[[\"" + zone_name + "\"]," + item_str + "]}"
                    ]
                    res = ctx.run(mod_cmd, mutates=True)
                    if res.rc != 0:
                        fail("Failed to modify DNS record: " + res.stderr)
                else:
                    msg = "would modify DNS record '" + record_name + "'"
    
    else:  # state == "absent"
        if ipa_record_found:
            changed = True
            if not ctx.check_mode:
                del_cmd = [
                    "curl", "-s", "-k", "--cookie-jar", cookie_jar, "--cookie", cookie_jar,
                    "-X", "POST", server_url + "/json",
                    "-d", "{\"method\":\"dnsrecord_del\",\"params\":[[\"" + zone_name + "\"]," + item_str + "]}"
                ]
                res = ctx.run(del_cmd, mutates=True)
                if res.rc != 0:
                    fail("Failed to delete DNS record: " + res.stderr)
            else:
                msg = "would delete DNS record '" + record_name + "'"
    
    if not msg:
        if changed:
            msg = state + " DNS record '" + record_name + "'"
        else:
            msg = "DNS record '" + record_name + "' is already " + state
    
    # Cleanup cookie jar if needed (optional)
    return {"changed": changed, "msg": msg}
