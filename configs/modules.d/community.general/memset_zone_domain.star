def main(ctx, params):
    api_key = params["api_key"]
    domain = params["domain"]
    state = params.get("state", "present")
    zone = params["zone"]

    # Validation: domain length must be <= 250 characters
    if len(domain) > 250:
        fail("Zone domain must be less than 250 characters in length.")

    # Helper: call Memset API (GET only)
    def api_get(method, payload=None):
        url = "https://api.memset.com/v1/json/" + method
        headers = {"Content-Type": "application/json"}
        # Build payload string if provided
        body = ""
        if payload != None and len(payload) > 0:
            # Simple JSON construction without json module
            parts = []
            for k, v in payload.items():
                # Escape strings naively (minimal needed for our cases)
                if type(v) == "string":
                    v = v.replace("\\", "\\\\").replace("\"", "\\\"")
                    parts.append('"%s":"%s"' % (k, v))
                else:
                    parts.append('"%s":%s' % (k, str(v).lower()))
            body = "{" + ",".join(parts) + "}"
        res = ctx.run(
            ["curl", "-s", "-X", "POST", "-H", "Content-Type: application/json",
             "-d", body, url],
            ok_codes=[0]
        )
        # curl rc=0 doesn't mean HTTP success; parse JSON manually
        if res.rc != 0:
            fail("API call failed: " + res.stderr)
        # Simple JSON parser for our expected response shape
        # Expected: {"result": ..., "error": ...}
        lines = res.stdout.split("\n")
        result = None
        error = None
        for line in lines:
            line = line.strip()
            if line.startswith('"result":'):
                result = line[len('"result":'):].strip().strip(",")
                # Handle simple string/bool/number
                if result.startswith('"') and result.endswith('"'):
                    result = result[1:-1]
                elif result == "true":
                    result = True
                elif result == "false":
                    result = False
            elif line.startswith('"error":'):
                error = line[len('"error":'):].strip().strip(",")
                if error.startswith('"') and error.endswith('"'):
                    error = error[1:-1]
        return result, error

    # Helper: list zone domains
    def list_zone_domains():
        result, error = api_get("dns.zone_domain_list", {})
        if error != None:
            fail("Failed to list zone domains: " + str(error))
        if result == None:
            return []
        # result should be a list of objects like {"domain": "...", ...}
        if type(result) != "list":
            fail("Unexpected API response format for dns.zone_domain_list")
        return result

    # Helper: check if domain exists
    def domain_exists():
        domains = list_zone_domains()
        for d in domains:
            if d.get("domain") == domain:
                return True
        return False

    # Helper: get zone_id by zone name
    def get_zone_id(zone_name):
        result, error = api_get("dns.zone_list", {})
        if error != None:
            fail("Failed to list zones: " + str(error))
        if result == None:
            fail("No zones returned by API")
        if type(result) != "list":
            fail("Unexpected API response format for dns.zone_list")
        zone_id = None
        for z in result:
            if z.get("zone") == zone_name:
                zone_id = z.get("id")
                break
        return zone_id

    # --- main logic ---

    # Determine zone_id
    zone_id = get_zone_id(zone)
    if zone_id == None:
        fail("DNS zone '%s' does not exist, cannot create domain." % zone)

    # Check current state
    current_exists = domain_exists()

    if state == "present":
        if current_exists:
            # Idempotent: domain already present
            return {"changed": False, "msg": "Domain %s already exists in zone %s" % (domain, zone)}
        if ctx.check_mode:
            return {"changed": True, "msg": "would create domain %s in zone %s" % (domain, zone)}
        # Create the domain
        payload = {"domain": domain, "zone_id": zone_id}
        result, error = api_get("dns.zone_domain_create", payload)
        if error != None:
            fail("Failed to create domain: " + str(error))
        # Fetch info to return
        info_payload = {"domain": domain}
        info_result, info_error = api_get("dns.zone_domain_info", info_payload)
        if info_error != None:
            # Still success, but no info
            return {"changed": True, "msg": "Domain %s created successfully" % domain}
        return {"changed": True, "msg": "Domain %s created successfully" % domain, "data": {"memset_api": info_result}}

    elif state == "absent":
        if not current_exists:
            # Idempotent: domain already absent
            return {"changed": False, "msg": "Domain %s does not exist in zone %s" % (domain, zone)}
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete domain %s from zone %s" % (domain, zone)}
        # Delete the domain
        payload = {"domain": domain}
        result, error = api_get("dns.zone_domain_delete", payload)
        if error != None:
            fail("Failed to delete domain: " + str(error))
        return {"changed": True, "msg": "Domain %s deleted successfully" % domain}

    else:
        fail("Unsupported state: " + str(state))
