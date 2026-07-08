def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    utm_host = params["utm_host"]
    utm_port = params.get("utm_port", 4444)
    utm_protocol = params.get("utm_protocol", "https")
    utm_token = params["utm_token"]
    validate_certs = params.get("validate_certs", True)
    
    # Build headers
    headers = {"X-Token": utm_token}
    headers.update(params.get("headers", {}))
    
    endpoint = "reverse_proxy/location"
    url = "%s://%s:%s/api/%s/%s" % (utm_protocol, utm_host, utm_port, endpoint, name)
    
    # Helper to build request body
    def build_body():
        body = {
            "name": name,
            "access_control": str(params.get("access_control", "0")),
            "allowed_networks": params.get("allowed_networks", ["REF_NetworkAny"]),
            "auth_profile": params.get("auth_profile", ""),
            "backend": params.get("backend", []),
            "be_path": params.get("be_path", ""),
            "comment": params.get("comment", ""),
            "denied_networks": params.get("denied_networks", []),
            "hot_standby": params.get("hot_standby", False),
            "path": params.get("path", "/"),
            "status": params.get("status", True),
            "stickysession_id": params.get("stickysession_id", "ROUTEID"),
            "stickysession_status": params.get("stickysession_status", False),
            "websocket_passthrough": params.get("websocket_passthrough", False)
        }
        return body
    
    # Check existing object using curl with --fail to get non-zero rc for 404
    extra_curl_args = []
    if not validate_certs:
        extra_curl_args.append("-k")
    
    res = ctx.run(["curl", "-s", "-f", "--silent", "-X", "GET", url, "-H", "Content-Type: application/json"] + extra_curl_args, mutates=False)
    object_exists = res.rc == 0
    
    if object_exists:
        if ctx.check_mode:
            if state == "absent":
                return {"changed": True, "msg": "Would delete proxy location %s" % name}
            else:
                return {"changed": False, "msg": "Object exists", "data": build_body()}
        
        if state == "absent":
            # Delete object
            res = ctx.run(["curl", "-s", "-f", "--silent", "-X", "DELETE", url, "-H", "Content-Type: application/json"] + extra_curl_args, mutates=True)
            if res.rc != 0:
                fail("Failed to delete proxy location %s: %s" % (name, res.stderr))
            return {"changed": True, "msg": "Deleted proxy location %s" % name}
        
        # Build body for update comparison and payload
        desired = build_body()
        
        # Construct JSON body manually
        allowed_networks_str = ",".join(["\"%s\"" % n for n in params.get("allowed_networks", ["REF_NetworkAny"])])
        backend_str = ",".join(["\"%s\"" % b for b in params.get("backend", [])])
        denied_networks_str = ",".join(["\"%s\"" % d for d in params.get("denied_networks", [])])
        hot_standby_str = "true" if params.get("hot_standby", False) else "false"
        status_str = "true" if params.get("status", True) else "false"
        stickysession_status_str = "true" if params.get("stickysession_status", False) else "false"
        websocket_passthrough_str = "true" if params.get("websocket_passthrough", False) else "false"
        
        body_str = "{\"name\":\"%s\",\"access_control\":\"%s\",\"allowed_networks\":[%s],\"auth_profile\":\"%s\",\"backend\":[%s],\"be_path\":\"%s\",\"comment\":\"%s\",\"denied_networks\":[%s],\"hot_standby\":%s,\"path\":\"%s\",\"status\":%s,\"stickysession_id\":\"%s\",\"stickysession_status\":%s,\"websocket_passthrough\":%s}" % (
            name,
            str(params.get("access_control", "0")),
            allowed_networks_str,
            params.get("auth_profile", ""),
            backend_str,
            params.get("be_path", ""),
            params.get("comment", ""),
            denied_networks_str,
            hot_standby_str,
            params.get("path", "/"),
            status_str,
            params.get("stickysession_id", "ROUTEID"),
            stickysession_status_str,
            websocket_passthrough_str
        )
        
        res = ctx.run([
            "curl", "-s", "-f", "--silent", "-X", "PUT", url,
            "-H", "Content-Type: application/json",
            "-d", body_str
        ] + extra_curl_args, mutates=True)
        
        if res.rc != 0:
            fail("Failed to update proxy location %s: %s" % (name, res.stderr))
        
        return {"changed": True, "msg": "Updated proxy location %s" % name, "data": desired}
    
    # Object doesn't exist
    if ctx.check_mode and state == "present":
        return {"changed": True, "msg": "Would create proxy location %s" % name}
    
    if state == "absent":
        return {"changed": False, "msg": "Object already absent"}
    
    # Create new object
    allowed_networks_str = ",".join(["\"%s\"" % n for n in params.get("allowed_networks", ["REF_NetworkAny"])])
    backend_str = ",".join(["\"%s\"" % b for b in params.get("backend", [])])
    denied_networks_str = ",".join(["\"%s\"" % d for d in params.get("denied_networks", [])])
    hot_standby_str = "true" if params.get("hot_standby", False) else "false"
    status_str = "true" if params.get("status", True) else "false"
    stickysession_status_str = "true" if params.get("stickysession_status", False) else "false"
    websocket_passthrough_str = "true" if params.get("websocket_passthrough", False) else "false"
    
    body_str = "{\"name\":\"%s\",\"access_control\":\"%s\",\"allowed_networks\":[%s],\"auth_profile\":\"%s\",\"backend\":[%s],\"be_path\":\"%s\",\"comment\":\"%s\",\"denied_networks\":[%s],\"hot_standby\":%s,\"path\":\"%s\",\"status\":%s,\"stickysession_id\":\"%s\",\"stickysession_status\":%s,\"websocket_passthrough\":%s}" % (
        name,
        str(params.get("access_control", "0")),
        allowed_networks_str,
        params.get("auth_profile", ""),
        backend_str,
        params.get("be_path", ""),
        params.get("comment", ""),
        denied_networks_str,
        hot_standby_str,
        params.get("path", "/"),
        status_str,
        params.get("stickysession_id", "ROUTEID"),
        stickysession_status_str,
        websocket_passthrough_str
    )
    
    res = ctx.run([
        "curl", "-s", "-f", "--silent", "-X", "POST", url,
        "-H", "Content-Type: application/json",
        "-d", body_str
    ] + extra_curl_args, mutates=True)
    
    if res.rc != 0:
        fail("Failed to create proxy location %s: %s" % (name, res.stderr))
    
    desired = build_body()
    return {"changed": True, "msg": "Created proxy location %s" % name, "data": desired}
