def main(ctx, params):
    zone_name = params["zone_name"]
    state = params.get("state", "present")
    dynamicupdate = params.get("dynamicupdate", False)
    allowsyncptr = params.get("allowsyncptr", False)
    ipa_host = params.get("ipa_host", "ipa.example.com")
    ipa_port = params.get("ipa_port", 443)
    ipa_prot = params.get("ipa_prot", "https")
    ipa_user = params.get("ipa_user", "admin")
    ipa_pass = params.get("ipa_pass")
    ipa_timeout = params.get("ipa_timeout", 10)
    validate_certs = params.get("validate_certs", True)

    if ipa_pass == None:
        fail("ipa_pass is required")

    # Build base URL
    base_url = ipa_prot + "://" + ipa_host + ":" + str(ipa_port) + "/ipa/session/json"

    # Helper: make POST request to IPA API
    def ipa_post(path, item):
        cmd = [
            "curl",
            "--silent",
            "--show-error",
            "--location",
            "--header", "Content-Type:application/json",
            "--header", "Accept:application/json",
            "--data", item,
            "--user", ipa_user + ":" + ipa_pass,
        ]
        if not validate_certs:
            cmd.extend(["--insecure"])
        if ipa_timeout != None:
            cmd.extend(["--connect-timeout", str(ipa_timeout)])
        cmd.append(base_url + path)
        res = ctx.run(cmd, mutates=False)
        if res.rc != 0:
            fail("IPA request failed: " + res.stderr)
        return res

    # Login by fetching session (uses cookie set by POST)
    res = ipa_post("/session/login_json", '{"method":"ping","params":[[],{}]}')

    # Parse JSON manually (simple extraction of first result)
    def parse_dnszone_find_result(json_str):
        # Basic parsing for {"result": {"result": [{...}]}}
        start = json_str.find('"result":')
        if start == -1:
            return None
        # Find first object after result key
        obj_start = json_str.find('{', start)
        if obj_start == -1:
            return None
        # Find matching closing brace for the inner object (simplified)
        depth = 0
        i = obj_start
        while i < len(json_str):
            if json_str[i] == '{':
                depth = depth + 1
            if json_str[i] == '}':
                depth = depth - 1
                if depth == 0:
                    return json_str[obj_start:i+1]
            i = i + 1
        return None

    # Check if zone exists via dnszone_find
    find_req = '{"method":"dnszone_find","params":[["' + zone_name + '"],{"all":true}]}'
    res = ipa_post("/json", find_req)
    zone_json = parse_dnszone_find_result(res.stdout)

    zone_exists = zone_json != None

    if state == "present":
        if not zone_exists:
            # Add zone
            add_req = '{"method":"dnszone_add","params":[["' + zone_name + '"],{"all":true,"idnsallowdynupdate":' + str(dynamicupdate).lower() + ',"idnsallowsyncptr":' + str(allowsyncptr).lower() + '}]}'
            if ctx.check_mode:
                return {"changed": True, "msg": "would create DNS zone " + zone_name}
            res = ipa_post("/json", add_req)
            return {"changed": True, "msg": "created DNS zone " + zone_name}
        else:
            # Parse existing settings
            # Extract idnsallowdynupdate and idnsallowsyncptr from zone_json (very basic extraction)
            dynupd = ""
            syncptr = ""
            i = 0
            s = zone_json
            # Find idnsallowdynupdate
            idx = s.find('"idnsallowdynupdate":')
            if idx != -1:
                i = idx + len('"idnsallowdynupdate":')
                while i < len(s) and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or s[i] == '\r'):
                    i = i + 1
                j = i
                while j < len(s) and s[j] != ',' and s[j] != '}':
                    j = j + 1
                dynupd = s[i:j]
            # Find idnsallowsyncptr
            idx = s.find('"idnsallowsyncptr":')
            if idx != -1:
                i = idx + len('"idnsallowsyncptr":')
                while i < len(s) and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or s[i] == '\r'):
                    i = i + 1
                j = i
                while j < len(s) and s[j] != ',' and s[j] != '}':
                    j = j + 1
                syncptr = s[i:j]

            desired_dynupd = "True" if dynamicupdate else "False"
            desired_syncptr = "True" if allowsyncptr else "False"

            if dynupd == desired_dynupd and syncptr == desired_syncptr:
                return {"changed": False, "msg": "DNS zone " + zone_name + " already exists with correct settings"}
            else:
                # Modify zone
                mod_req = '{"method":"dnszone_mod","params":[["' + zone_name + '"],{"all":true,"idnsallowdynupdate":' + str(dynamicupdate).lower() + ',"idnsallowsyncptr":' + str(allowsyncptr).lower() + '}]}'
                if ctx.check_mode:
                    return {"changed": True, "msg": "would update DNS zone " + zone_name}
                res = ipa_post("/json", mod_req)
                return {"changed": True, "msg": "updated DNS zone " + zone_name}
    else:
        # state == "absent"
        if not zone_exists:
            return {"changed": False, "msg": "DNS zone " + zone_name + " does not exist"}
        else:
            # Delete zone
            del_req = '{"method":"dnszone_del","params":[["' + zone_name + '"],{}]}'
            if ctx.check_mode:
                return {"changed": True, "msg": "would delete DNS zone " + zone_name}
            res = ipa_post("/json", del_req)
            return {"changed": True, "msg": "deleted DNS zone " + zone_name}
