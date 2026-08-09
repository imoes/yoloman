def main(ctx, params):
    url = params["auth_keycloak_url"]
    realm = params.get("realm", "master")
    validate_certs = params.get("validate_certs", True)

    # Build curl args for GET request to Keycloak public info endpoint
    verify_flag = "" if validate_certs else "-k"
    endpoint = url.rstrip("/") + "/realms/" + realm + "/protocol/openid-connect"
    
    # Probe realm metadata (public info)
    cmd = ["curl", "-s", "-S", "-X", "GET", endpoint]
    if verify_flag:
        cmd.insert(1, verify_flag)
    
    res = ctx.run(cmd, mutates=False)
    
    if res.rc != 0:
        fail("failed to get realm info: " + res.stderr)
    
    # Parse JSON manually (no json module)
    body = res.stdout
    if not body:
        fail("empty response from Keycloak endpoint")
    
    # Extract required fields using simple string search
    realm_info = {}
    
    # realm
    realm_str = '"realm":"'
    start = body.find(realm_str)
    if start != -1:
        start += len(realm_str)
        end = body.find('"', start)
        if end != -1:
            realm_info["realm"] = body[start:end]
    else:
        realm_info["realm"] = realm
    
    # public_key
    pk_str = '"public_key":"'
    start = body.find(pk_str)
    if start != -1:
        start += len(pk_str)
        end = body.find('"', start)
        if end != -1:
            realm_info["public_key"] = body[start:end]
    
    # token-service
    ts_str = '"token-service":"'
    start = body.find(ts_str)
    if start != -1:
        start += len(ts_str)
        end = body.find('"', start)
        if end != -1:
            realm_info["token-service"] = body[start:end]
    
    # account-service
    ac_str = '"account-service":"'
    start = body.find(ac_str)
    if start != -1:
        start += len(ac_str)
        end = body.find('"', start)
        if end != -1:
            realm_info["account-service"] = body[start:end]
    
    # tokens-not-before (integer)
    tnb_str = '"tokens-not-before":'
    start = body.find(tnb_str)
    if start != -1:
        start += len(tnb_str)
        num_str = ""
        for c in body[start:]:
            if c.isdigit():
                num_str += c
            elif num_str:
                break
        if num_str:
            realm_info["tokens-not-before"] = int(num_str)
    
    return {
        "changed": False,
        "msg": "Get realm public info successful for ID " + realm,
        "realm_info": realm_info
    }
