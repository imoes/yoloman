def main(ctx, params):
    baseuri = params["baseuri"]
    category = params["category"]
    command_list = params["command"]
    username = params.get("username")
    password = params.get("password")
    auth_token = params.get("auth_token")
    timeout = str(params.get("timeout", 10))
    resource_id = params.get("resource_id")

    # Validate authentication: must have username+password OR auth_token
    has_creds = username != None and password != None
    has_token = auth_token != None
    if not (has_creds or has_token):
        fail("authentication: provide either username+password or auth_token")
    if has_creds and has_token:
        fail("authentication: cannot use both credentials and auth_token")

    # Validate category
    valid_categories = ["Systems", "Accounts", "Manager"]
    if category not in valid_categories:
        fail("invalid category '" + category + "'. Valid categories = " + str(valid_categories))

    # Validate commands per category
    valid_commands_by_category = {
        "Systems": ["CreateBiosConfigJob"],
        "Accounts": [],
        "Manager": []
    }
    valid_commands = valid_commands_by_category.get(category, [])
    for cmd in command_list:
        if cmd not in valid_commands:
            fail("invalid command '" + cmd + "' for category '" + category + "'. Valid commands = " + str(valid_commands))

    root_uri = "https://" + baseuri
    manager_uri = root_uri + "/redfish/v1/Managers/iDRAC.Embedded.1"
    system_uri = root_uri + "/redfish/v1/Systems/System.Embedded.1"

    # Helper: construct auth header
    def auth_headers():
        if has_token:
            return {"X-Auth-Token": auth_token}
        else:
            return {"Authorization": "Basic " + (username + ":" + password).encode("utf-8").hex().upper()}

    # Helper: perform GET request via curl
    def redfish_get(path, headers_extra=None):
        headers = {"Accept": "application/json", "Content-Type": "application/json"}
        if headers_extra:
            headers.update(headers_extra)
        args = ["curl", "-sk", "-X", "GET", "--connect-timeout", timeout, "--max-time", timeout]
        for k, v in headers.items():
            args += ["-H", k + ": " + v]
        args.append(path)
        res = ctx.run(args, mutates=False)
        if res.rc != 0:
            fail("GET " + path + " failed: " + res.stderr)
        return res.stdout

    # Helper: perform POST request via curl
    def redfish_post(path, payload_str, headers_extra=None):
        headers = {"Accept": "application/json", "Content-Type": "application/json"}
        if headers_extra:
            headers.update(headers_extra)
        args = ["curl", "-sk", "-X", "POST", "--connect-timeout", timeout, "--max-time", timeout, "-d", payload_str]
        for k, v in headers.items():
            args += ["-H", k + ": " + v]
        args.append(path)
        res = ctx.run(args, mutates=True)
        if res.rc != 0:
            fail("POST " + path + " failed: " + res.stderr)
        return res.stdout, res.rc

    # Step 1: get system resource (Systems category)
    if category == "Systems":
        # Find systems resource URI via /redfish/v1/Systems
        systems_json = redfish_get(root_uri + "/redfish/v1/Systems", auth_headers())
        if '"Members": []' in systems_json or '"Members":[]' in systems_json:
            fail("no systems found")
        # Extract first member URI — simple heuristic: find first @odata.id in Members array
        members = systems_json.split('"Members":')[1].split("]")[0]
        if not members.strip():
            fail("no systems found")
        members_list = members.split("{")
        if len(members_list) < 2:
            fail("could not parse Systems members URI")
        uri_part = members_list[1]
        if '"@odata.id"' not in uri_part:
            fail("could not parse Systems member @odata.id")
        parts = uri_part.split('"@odata.id"')
        if len(parts) < 2:
            fail("could not parse Bios URI")
        val = parts[1].split(":")[1].strip()
        if not val.startswith('"'):
            fail("could not parse Bios URI")
        systems_member_uri = val[1:val.index('"', 1)]
        # For Systems category we ignore resource_id because the BIOS job targets the Manager
        # So we override and don't use resource_id here per original code comment.

        # Get first system details
        system_details = redfish_get(root_uri + systems_member_uri, auth_headers())
        if '"Bios"' not in system_details:
            fail("Bios resource not found on system")
        bios_match = system_details.find('"Bios"')
        if bios_match == -1:
            fail("could not parse Bios URI")
        bios_json = system_details[bios_match:bios_match+200]
        bios_uri_start = bios_json.find('"@odata.id"')
        if bios_uri_start == -1:
            fail("could not parse Bios URI")
        bios_uri_val = bios_json[bios_uri_start:].split(":")[1].strip()
        if not bios_uri_val.startswith('"'):
            fail("could not parse Bios URI")
        bios_uri = bios_uri_val[1:bios_uri_val.index('"', 1)]

        # Get Bios settings URI (via @Redfish.Settings)
        bios_details = redfish_get(root_uri + bios_uri, auth_headers())
        settings_idx = bios_details.find('"@Redfish.Settings"')
        if settings_idx == -1:
            fail("could not parse Bios Settings URI")
        settings_json = bios_details[settings_idx:settings_idx+300]
        settings_obj_idx = settings_json.find('"SettingsObject"')
        if settings_obj_idx == -1:
            fail("could not parse Bios Settings URI")
        settings_obj_json = settings_json[settings_obj_idx:]
        settings_uri_start = settings_obj_json.find('"@odata.id"')
        if settings_uri_start == -1:
            fail("could not parse Bios Settings URI")
        settings_uri_val = settings_obj_json[settings_uri_start:].split(":")[1].strip()
        if not settings_uri_val.startswith('"'):
            fail("could not parse Bios Settings URI")
        bios_settings_uri = settings_uri_val[1:settings_uri_val.index('"', 1)]

        # POST to Jobs collection to create BIOS config job
        jobs_uri = manager_uri + "/Jobs"
        payload_str = '{"TargetSettingsURI": "' + bios_settings_uri + '"}'
        job_json, rc = redfish_post(jobs_uri, payload_str, auth_headers())

        # Extract job ID — parse response JSON body
        # iDRAC usually returns {"JobID":"JID_xxxxx","JobUri":"/redfish/v1/Managers/iDRAC.Embedded.1/Jobs/JID_xxxxx"}
        job_data = job_json.strip()
        if not job_data.startswith("{") or not job_data.endswith("}"):
            fail("could not parse job response JSON")
        # Extract JobUri field
        job_uri_start = job_data.find('"JobUri"')
        job_id_full = None
        if job_uri_start != -1:
            rest = job_data[job_uri_start:]
            val_part = rest.split(":", 1)[1].strip()
            if val_part.startswith('"'):
                job_id_full = val_part[1:val_part.index('"', 1)]
        # Fallback to JobID
        if not job_id_full:
            job_id_start = job_data.find('"JobID"')
            if job_id_start != -1:
                rest = job_data[job_id_start:]
                val_part = rest.split(":", 1)[1].strip()
                if val_part.startswith('"'):
                    job_id_full = val_part[1:val_part.index('"', 1)]
        if not job_id_full:
            fail("could not extract job ID from response body — ensure iDRAC firmware is current")

        return {"changed": True, "msg": "Config job " + job_id_full + " created", "data": {"job_id": job_id_full}}
    else:
        # No other commands implemented — fail if category is not Systems
        fail("only category 'Systems' with command 'CreateBiosConfigJob' is supported in this Starlark module")
