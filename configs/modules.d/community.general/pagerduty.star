def main(ctx, params):
    state = params["state"]
    token = params["token"]
    validate_certs = params.get("validate_certs", True)
    
    # Validate state
    if state not in ["running", "started", "ongoing", "absent"]:
        fail("invalid state: " + state + " (must be one of: running, started, ongoing, absent)")
    
    # Handle 'ongoing' state
    if state == "ongoing":
        url = "https://api.pagerduty.com/maintenance_windows?filter=ongoing"
        headers = [
            "Content-Type: application/json",
            "Authorization: Token token=" + token,
            "Accept: application/vnd.pagerduty+json;version=2"
        ]
        res = ctx.run(["curl", "-s", "-X", "GET"] + headers + [url], mutates=False)
        if res.rc != 0:
            fail("failed to fetch ongoing windows: " + res.stderr)
        result = res.stdout.strip()
        if result == "" or result == "[]":
            return {"changed": False, "msg": "no ongoing maintenance windows", "result": {"maintenance_windows": []}}
        return {"changed": False, "msg": "retrieved ongoing windows", "result": result}
    
    # Handle 'absent' state
    if state == "absent":
        window_id = params.get("window_id")
        if window_id == None or window_id == "":
            fail("window_id is required when state is absent")
        url = "https://api.pagerduty.com/maintenance_windows/" + window_id
        headers = [
            "Content-Type: application/json",
            "Authorization: Token token=" + token,
        ]
        res = ctx.run(["curl", "-s", "-X", "DELETE"] + headers + [url], mutates=False)
        # curl returns 0 on success, and 22 for 204 No Content
        if res.rc == 0 or res.rc == 22:
            return {"changed": True, "msg": "maintenance window deleted"}
        fail("failed to delete maintenance window: " + res.stderr)
    
    # Handle 'running' or 'started' state
    if state == "running" or state == "started":
        service = params.get("service")
        if service == None or (type(service) == "list" and len(service) == 0):
            fail("service is required when state is running or started")
        
        requester_id = params.get("requester_id")
        if requester_id == None or requester_id == "":
            fail("requester_id is required when creating a maintenance window")
        
        hours = params.get("hours", "1")
        minutes = params.get("minutes", "0")
        desc = params.get("desc", "Created by Ansible")
        
        # Build service list payload
        service_list = []
        if type(service) == "string":
            service_list = [service]
        else:
            for s in service:
                service_list.append(s)
        
        services_payload = ""
        for i in range(len(service_list)):
            if i > 0:
                services_payload = services_payload + ","
            services_payload = services_payload + "{\"id\":\"" + service_list[i] + "\",\"type\":\"service_reference\"}"
        
        # Build request JSON — note: Starlark has no datetime; we use fixed dummy start/end
        # Since the original required datetime.utcnow() and Starlark lacks it, we must fail
        fail("this module cannot compute maintenance window times in Starlark (missing datetime); please precompute start/end times or avoid this module in Starlark runtime")
    
    return {"changed": False, "msg": "no action taken"}
