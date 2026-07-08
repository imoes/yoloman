def main(ctx, params):
    project_id = params.get("project_id")
    instance_id = params.get("instance_id")
    endpoint = params.get("endpoint", "ovh-eu")
    application_key = params.get("application_key")
    application_secret = params.get("application_secret")
    consumer_key = params.get("consumer_key")

    if project_id == None or instance_id == None:
        fail("project_id and instance_id are required")

    # Build API URL
    base_url = "https://" + endpoint + ".ovh.com"
    project_endpoint = "/cloud/project/" + project_id
    instance_endpoint = project_endpoint + "/instance/" + instance_id

    # Check project exists (read-only probe)
    res = ctx.run(["curl", "-s", "-f", "-X", "GET", base_url + project_endpoint], mutates=False)
    if res.rc != 0:
        fail("project %s does not exist" % project_id)

    # Check instance exists (read-only probe)
    res = ctx.run(["curl", "-s", "-f", "-X", "GET", base_url + instance_endpoint], mutates=False)
    if res.rc != 0:
        fail("instance %s does not exist in project %s" % (instance_id, project_id))

    # Check monthly billing status (read-only probe)
    instance_res = ctx.run([
        "curl", "-s", "-f", "-X", "GET",
        base_url + instance_endpoint,
        "-H", "Accept: application/json"
    ], mutates=False)
    if instance_res.rc != 0:
        fail("failed to retrieve instance info")

    # Parse instance JSON manually (no json module) — look for "monthlyBilling"
    instance_json = instance_res.stdout
    # Extract monthlyBilling status using string search
    status_start = instance_json.find('"monthlyBilling":')
    if status_start == -1:
        fail("monthlyBilling field not found in instance response")

    # Skip to the nested object start
    obj_start = instance_json.find("{", status_start)
    if obj_start == -1:
        fail("could not parse monthlyBilling object")

    # Extract minimal object for status check — look for "status" key
    status_key = instance_json.find('"status":', obj_start)
    if status_key == -1:
        fail("status field not found in monthlyBilling")

    # Find string value — simple heuristic for double-quoted value
    quote1 = instance_json.find('"', status_key + len('"status":'))
    if quote1 == -1:
        fail("could not parse status value")
    quote2 = instance_json.find('"', quote1 + 1)
    if quote2 == -1:
        fail("could not parse status value")
    status_val = instance_json[quote1 + 1:quote2]

    if status_val == "ok" or status_val == "activationPending":
        return {"changed": False, "msg": "monthly billing already active or pending"}

    if ctx.check_mode:
        return {"changed": True, "msg": "would enable monthly billing"}

    # Enable monthly billing
    enable_url = base_url + instance_endpoint + "/activeMonthlyBilling"
    enable_res = ctx.run([
        "curl", "-s", "-f", "-X", "POST",
        enable_url,
        "-H", "Content-Type: application/json"
    ], mutates=True)

    if enable_res.skipped:
        # Should not happen because mutates=True and not check_mode, but handle defensively
        return {"changed": True, "msg": "would enable monthly billing"}

    if enable_res.rc != 0:
        fail("failed to enable monthly billing: " + enable_res.stderr)

    # Parse result for reporting
    result_json = enable_res.stdout
    status_start = result_json.find('"monthlyBilling":')
    if status_start == -1:
        fail("monthlyBilling field not found in enable response")

    obj_start = result_json.find("{", status_start)
    if obj_start == -1:
        fail("could not parse monthlyBilling object in enable response")

    status_key = result_json.find('"status":', obj_start)
    if status_key == -1:
        fail("status field not found in monthlyBilling of enable response")

    quote1 = result_json.find('"', status_key + len('"status":'))
    if quote1 == -1:
        fail("could not parse status value in enable response")
    quote2 = result_json.find('"', quote1 + 1)
    if quote2 == -1:
        fail("could not parse status value in enable response")
    new_status = result_json[quote1 + 1:quote2]

    return {
        "changed": True,
        "msg": "monthly billing enabled (status: %s)" % new_status,
        "data": {"monthly_billing_status": new_status}
    }
