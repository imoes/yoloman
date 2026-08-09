def main(ctx, params):
    # Extract parameters
    repository = params["repository"]
    workspace = params["workspace"]
    name = params["name"]
    state = params["state"]
    secured = params.get("secured", False)
    value = params.get("value")

    # Validate required parameters
    if state == "present" and value == None:
        fail("`value` is required when the `state` is `present`")

    # Construct Bitbucket API base URL
    base_url = "https://api.bitbucket.org/2.0/repositories/" + workspace + "/" + repository + "/pipelines_config/variables/"
    variable_url = base_url + name

    # For secured variables, we always report changed due to security constraints
    # (Bitbucket API does not return the actual value of secured variables)
    if state == "absent":
        # Try to fetch existing variable to get its UUID
        res = ctx.run(["curl", "-sS", "-u", ctx.facts().get("bitbucket_auth", ""), "-X", "GET", base_url], mutates=False)
        if res.rc != 0:
            fail("Failed to retrieve pipeline variables: " + res.stderr)
        # Parse JSON manually (no json module)
        # Extract values array - simplified parsing
        values_str = res.stdout
        # Look for our variable in the list
        if ("\"key\":\"" + name + "\"") in values_str:
            # Variable exists, delete it
            if not ctx.check_mode:
                delete_res = ctx.run(["curl", "-sS", "-u", ctx.facts().get("bitbucket_auth", ""), "-X", "DELETE", variable_url], mutates=True)
                if delete_res.rc != 0 and delete_res.rc != 204:
                    fail("Failed to delete pipeline variable: " + delete_res.stderr)
            return {"changed": True, "msg": "deleted pipeline variable " + name}
        else:
            return {"changed": False, "msg": "pipeline variable " + name + " not found"}
    elif state == "present":
        # Check if variable exists and compare values
        res = ctx.run(["curl", "-sS", "-u", ctx.facts().get("bitbucket_auth", ""), "-X", "GET", base_url], mutates=False)
        if res.rc != 0:
            fail("Failed to retrieve pipeline variables: " + res.stderr)

        # Check if variable exists
        found = False
        existing_secured = False
        existing_value = None

        # Simple parsing for JSON array elements
        # Look for our variable in the output
        lines = res.stdout.split("\n")
        for line in lines:
            if "\"key\":\"" + name + "\"" in line:
                found = True
                if "\"secured\":true" in line or "\"secured\": true" in line:
                    existing_secured = True
                # For non-secured variables, try to extract value
                if not existing_secured:
                    # Extract value field
                    if "\"value\":\"" in line:
                        # Extract value between quotes after "value":
                        idx = line.find("\"value\":\"")
                        if idx >= 0:
                            start = idx + len("\"value\":\"")
                            end = line.find("\"", start)
                            if end > start:
                                existing_value = line[start:end]

        # For secured variables, we always return changed=True because we can't compare values
        if existing_secured:
            if not ctx.check_mode:
                # Update secured variable
                update_res = ctx.run([
                    "curl", "-sS", "-u", ctx.facts().get("bitbucket_auth", ""),
                    "-X", "PUT", variable_url,
                    "-H", "Content-Type: application/json",
                    "-d", "{\"value\":\"" + value + "\",\"secured\":true}"
                ], mutates=True)
                if update_res.rc != 0:
                    fail("Failed to update secured pipeline variable: " + update_res.stderr)
            return {"changed": True, "msg": "updated secured pipeline variable " + name}

        if found and existing_value == value:
            return {"changed": False, "msg": "pipeline variable " + name + " already has correct value"}
        else:
            if found:
                # Update existing variable
                if not ctx.check_mode:
                    update_res = ctx.run([
                        "curl", "-sS", "-u", ctx.facts().get("bitbucket_auth", ""),
                        "-X", "PUT", variable_url,
                        "-H", "Content-Type: application/json",
                        "-d", "{\"value\":\"" + value + "\",\"secured\":" + str(secured).lower() + "}"
                    ], mutates=True)
                    if update_res.rc != 0:
                        fail("Failed to update pipeline variable: " + update_res.stderr)
            else:
                # Create new variable
                if not ctx.check_mode:
                    create_res = ctx.run([
                        "curl", "-sS", "-u", ctx.facts().get("bitbucket_auth", ""),
                        "-X", "POST", base_url,
                        "-H", "Content-Type: application/json",
                        "-d", "{\"key\":\"" + name + "\",\"value\":\"" + value + "\",\"secured\":" + str(secured).lower() + "}"
                    ], mutates=True)
                    if create_res.rc != 0:
                        fail("Failed to create pipeline variable: " + create_res.stderr)
            return {"changed": True, "msg": "created or updated pipeline variable " + name}
