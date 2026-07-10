def main(ctx, params):
    # Extract parameters
    state = params.get("state", "present")
    name = params.get("name")
    resource_type = params.get("resource_type")
    alerts = params.get("alerts", [])
    notes = params.get("notes", "")
    manageiq_connection = params.get("manageiq_connection", {})
    
    # Validate required parameters
    if state == "present":
        if name == None:
            ctx.fail("name is required when state is present")
        if resource_type == None:
            ctx.fail("resource_type is required when state is present")
        if alerts == None or len(alerts) == 0:
            ctx.fail("alerts is required when state is present")
    elif state == "absent":
        if name == None:
            ctx.fail("name is required when state is absent")
    
    # Build connection parameters with environment fallback
    url = manageiq_connection.get("url")
    username = manageiq_connection.get("username")
    password = manageiq_connection.get("password")
    token = manageiq_connection.get("token")
    ca_cert = manageiq_connection.get("ca_cert")
    validate_certs = manageiq_connection.get("validate_certs", True)
    
    # Environment variable fallbacks
    if url == None:
        url = ctx.env("MIQ_URL")
    if token == None:
        token = ctx.env("MIQ_TOKEN")
    if username == None:
        username = ctx.env("MIQ_USERNAME")
    if password == None:
        password = ctx.env("MIQ_PASSWORD")
    
    # Validate required connection params
    if url == None:
        ctx.fail("url is required (or set MIQ_URL environment variable)")
    if token == None and username == None:
        ctx.fail("token or username is required (or set MIQ_TOKEN/MIQ_USERNAME environment variable)")
    if token == None and password == None:
        ctx.fail("password is required when not using token (or set MIQ_PASSWORD environment variable)")
    
    # Determine API endpoint
    api_url = url.rstrip("/")
    profiles_url = api_url + "/api/alert_definition_profiles"
    alerts_url = api_url + "/api/alert_definitions"
    
    # Check if profile exists
    res = ctx.run([ctx.bin("curl"), "-s", "-X", "GET", profiles_url,
                   "-H", "Content-Type: application/json",
                   "-u", username + ":" + password,
                   "-k" if not validate_certs else "--cacert", ca_cert if ca_cert else ""],
                  ok_codes=[0])
    if res.rc != 0:
        ctx.fail("Failed to list alert profiles: " + res.stderr)
    
    # Parse JSON manually (no json module available)
    profiles_data = res.stdout
    existing_profile = None
    lines = profiles_data.split("\n")
    for line in lines:
        if '"name": "' + name + '"' in line or '"name":" ' + name + '"' in line or '"name":"' + name + '"' in line:
            # Extract href from profile
            for subline in lines:
                if '"href":' in subline:
                    # Simple extraction - get the href value
                    idx = subline.find('"href":')
                    if idx != -1:
                        href_start = subline.find('"', idx + 7) + 1
                        href_end = subline.find('"', href_start)
                        if href_end != -1:
                            href = subline[href_start:href_end]
                            existing_profile = {"href": href}
                            break
            break
    
    # Handle absent state
    if state == "absent":
        if existing_profile == None:
            return {"changed": False, "msg": "Alert profile '" + name + "' does not exist in ManageIQ"}
        
        res = ctx.run([ctx.bin("curl"), "-s", "-X", "POST", existing_profile["href"],
                       "-H", "Content-Type: application/json",
                       "-u", username + ":" + password,
                       "-d", '{"action":"delete"}',
                       "-k" if not validate_certs else "--cacert", ca_cert if ca_cert else ""],
                      ok_codes=[0])
        if res.rc != 0:
            ctx.fail("Failed to delete profile: " + res.stderr)
        
        return {"changed": True, "msg": "Successfully deleted profile '" + name + "'"}
    
    # Handle present state
    # Get alert hrefs first (to fail early if missing)
    alert_hrefs = []
    for alert_desc in alerts:
        res = ctx.run([ctx.bin("curl"), "-s", "-X", "GET", alerts_url + '?filter_eq[description]=' + alert_desc,
                       "-H", "Content-Type: application/json",
                       "-u", username + ":" + password,
                       "-k" if not validate_certs else "--cacert", ca_cert if ca_cert else ""],
                      ok_codes=[0])
        if res.rc != 0:
            ctx.fail("Failed to get alert definitions: " + res.stderr)
        
        # Parse response to find alert href
        alert_data = res.stdout
        if '"href":' in alert_data:
            idx = alert_data.find('"href":')
            if idx != -1:
                href_start = alert_data.find('"', idx + 7) + 1
                href_end = alert_data.find('"', href_start)
                if href_end != -1:
                    alert_hrefs.append(alert_data[href_start:href_end])
    
    if existing_profile == None:
        # Create new profile
        profile_dict = '{"name":" ' + name + '","description":" ' + name + '","mode":" ' + resource_type + '"}'
        if notes != "":
            profile_dict = '{"name":" ' + name + '","description":" ' + name + '","mode":" ' + resource_type + '","set_data":{"notes":" ' + notes + '"}}'
        
        res = ctx.run([ctx.bin("curl"), "-s", "-X", "POST", profiles_url,
                       "-H", "Content-Type: application/json",
                       "-u", username + ":" + password,
                       "-d", profile_dict,
                       "-k" if not validate_certs else "--cacert", ca_cert if ca_cert else ""],
                      ok_codes=[0])
        if res.rc != 0:
            ctx.fail("Failed to create profile: " + res.stderr)
        
        # Assign alerts to new profile
        res = ctx.run([ctx.bin("curl"), "-s", "-X", "POST", existing_profile["href"] + "/alert_definitions",
                       "-H", "Content-Type: application/json",
                       "-u", username + ":" + password,
                       "-d", '{"action":"assign","resources":' + str(alert_hrefs) + '}',
                       "-k" if not validate_certs else "--cacert", ca_cert if ca_cert else ""],
                      ok_codes=[0])
        if res.rc != 0:
            ctx.fail("Failed to assign alerts to profile: " + res.stderr)
        
        return {"changed": True, "msg": "Profile '" + name + "' created successfully"}
    
    # Update existing profile
    res = ctx.run([ctx.bin("curl"), "-s", "-X", "GET", existing_profile["href"] + '?expand=alert_definitions',
                   "-H", "Content-Type: application/json",
                   "-u", username + ":" + password,
                   "-k" if not validate_certs else "--cacert", ca_cert if ca_cert else ""],
                  ok_codes=[0])
    if res.rc != 0:
        ctx.fail("Failed to get profile details: " + res.stderr)
    
    # Compare and determine changes needed
    profile_data = res.stdout
    changed = False
    
    # Check if resource_type needs update
    if '"mode":"' + resource_type + '"' not in profile_data and '"mode": "' + resource_type + '"' not in profile_data:
        changed = True
    
    # Check if notes need update
    notes_in_profile = '"notes":' in profile_data and '"notes": "' + notes + '"' not in profile_data
    if notes != "" and '"set_data":{"notes":' not in profile_data:
        changed = True
    elif notes_in_profile:
        changed = True
    
    # For simplicity in Starlark, always update if anything might have changed
    if changed:
        update_dict = '{"mode":" ' + resource_type + '"}'
        if notes != "":
            update_dict = '{"mode":" ' + resource_type + '","set_data":{"notes":" ' + notes + '"}}'
        
        res = ctx.run([ctx.bin("curl"), "-s", "-X", "POST", existing_profile["href"],
                       "-H", "Content-Type: application/json",
                       "-u", username + ":" + password,
                       "-d", update_dict,
                       "-k" if not validate_certs else "--cacert", ca_cert if ca_cert else ""],
                      ok_codes=[0])
        if res.rc != 0:
            ctx.fail("Failed to update profile: " + res.stderr)
        
        return {"changed": True, "msg": "Profile '" + name + "' updated successfully"}
    
    return {"changed": False, "msg": "No update needed for profile '" + name + "'"}
