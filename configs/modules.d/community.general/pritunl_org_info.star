def main(ctx, params):
    # Required parameters
    api_token = params.get("pritunl_api_token")
    api_secret = params.get("pritunl_api_secret")
    pritunl_url = params.get("pritunl_url")
    
    # Optional parameters
    org_name = params.get("organization")
    validate_certs = params.get("validate_certs", True)
    
    # Validate required parameters
    if api_token == None:
        fail("pritunl_api_token is required")
    if api_secret == None:
        fail("pritunl_api_secret is required")
    if pritunl_url == None:
        fail("pritunl_url is required")
    
    # Build headers for Pritunl API authentication
    import_time = str(int(__import__("time").time())) if "time" in dir(__builtins__) else "0"
    # Note: __import__ is not available in Starlark; we'll simulate timestamp generation
    
    # Simulate timestamp (this is a limitation - no time module available)
    # For Starlark, we'll use a placeholder; real implementation would need ctx support
    # In practice, this module would require ctx.run to call the API with proper headers
    fail("pritunl_org_info requires HTTP client support (e.g., curl) not yet exposed via ctx")

    # Below is the theoretical implementation structure if ctx had HTTP support:
    #
    # auth_timestamp = str(int(time.time()))
    # auth_string = api_token + pritunl_url + auth_timestamp
    # auth_signature = hmac(api_secret, auth_string).hexdigest()
    # 
    # headers = {
    #     "Content-Type": "application/json",
    #     "Authentication": api_token,
    #     "Timestamp": auth_timestamp,
    #     "Signature": auth_signature
    # }
    #
    # # Build URL
    # url = pritunl_url.rstrip("/") + "/organization"
    # if org_name:
    #     url += "?name=" + org_name
    # 
    # # Make request (this would use ctx.run with curl)
    # # curl -s -k [args...] [url]
    # curl_args = ["curl", "-s", "-k", "-X", "GET", url]
    # if not validate_certs:
    #     # -k already added above
    #     pass
    # curl_args.extend(["-H", "Authentication: " + api_token])
    # curl_args.extend(["-H", "Timestamp: " + auth_timestamp])
    # curl_args.extend(["-H", "Signature: " + auth_signature])
    # curl_args.extend(["-H", "Content-Type: application/json"])
    # 
    # res = ctx.run(curl_args)
    # if res.rc != 0:
    #     fail("Failed to fetch organizations: " + res.stderr)
    # 
    # # Parse JSON manually (Starlark has no json module)
    # # This would require a custom JSON parser - not implemented in Starlark
    # organizations = parse_json_manually(res.stdout)
    #
    # if org_name != None and len(organizations) == 0:
    #     fail("Organization '%s' does not exist" % org_name)
    #
    # return {
    #     "changed": False,
    #     "organizations": organizations
    # }
