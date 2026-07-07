def main(ctx, params):
    client_id = params.get("client_id", 1)
    domain_name = params["domain_name"]
    verification_method = params["verification_method"]
    verification_email = params.get("verification_email")
    entrust_api_user = params["entrust_api_user"]
    entrust_api_key = params["entrust_api_key"]
    entrust_api_client_cert_path = params["entrust_api_client_cert_path"]
    entrust_api_client_cert_key_path = params["entrust_api_client_cert_key_path"]

    # Validate verification_email usage
    if verification_email and verification_method != "email":
        fail('The verification_email field is invalid when verification_method="' + verification_method + '".')

    # Authentication and headers for ECS API calls
    auth_args = ["-E", entrust_api_client_cert_path, "--key", entrust_api_client_cert_key_path, "-u", entrust_api_user + ":" + entrust_api_key]
    headers = ["-H", "Content-Type: application/json"]

    # Helper to make ECS API GET calls
    def ecs_get(path):
        return ctx.run(["curl", "-s", "-S", "-f"] + auth_args + headers + ["https://cloud.entrust.net/EntrustCloud/api/v1" + path], mutates=False)

    # Helper to make ECS API POST calls
    def ecs_post(path, payload):
        return ctx.run(["curl", "-s", "-S", "-f", "-X", "POST", "-d", payload] + auth_args + headers + ["https://cloud.entrust.net/EntrustCloud/api/v1" + path], mutates=True)

    # Query current domain status
    res_get = ecs_get("/domains/" + domain_name + "?clientId=" + str(client_id))
    domain_status = None
    verification_method_current = None
    domain_details_raw = ""

    if res_get.rc == 0:
        domain_status = "present"
        domain_details_raw = res_get.stdout
        # Parse basic fields from JSON output using string operations (safe subset)
        # Extract verificationStatus
        vs = _extract_json_string(res_get.stdout, "verificationStatus")
        if vs != None:
            domain_status = vs
        # Extract verificationMethod
        vm = _extract_json_string(res_get.stdout, "verificationMethod")
        if vm != None:
            verification_method_current = vm.lower()
    elif "Domain not found" in res_get.stderr or "404" in res_get.stderr:
        domain_status = None
        domain_details_raw = ""
    else:
        fail("Failed to query domain status from ECS: " + res_get.stderr)

    # Determine if change is needed
    if domain_status == "APPROVED":
        return {"changed": False, "msg": "Domain is already approved"}
    if (domain_status == "INITIAL_VERIFICATION" or domain_status == "RE_VERIFICATION") and verification_method_current == verification_method:
        return {"changed": False, "msg": "Domain verification already in progress with same method"}

    if ctx.check_mode:
        return {"changed": True, "msg": "would request domain validation or revalidation for " + domain_name}

    # Build request body
    body = '{"verificationMethod": "' + verification_method.upper() + '"'
    if verification_method == "email":
        if verification_email:
            body = body + ',"emailMethod": {"emailSource": "SPECIFIED", "email": "' + verification_email + '"}'
        else:
            body = body + ',"emailMethod": {"emailSource": "INCLUDE_WHOIS"}'
    body = body + '}'

    if domain_status == None:
        res_post = ecs_post("/domains?clientId=" + str(client_id), body)
    else:
        res_post = ecs_post("/domains/" + domain_name + "?clientId=" + str(client_id), body)

    if res_post.rc != 0:
        fail("Failed to request domain validation from Entrust (ECS): " + res_post.stderr)

    # Wait for validation data (DNS/web_server) to populate
    if verification_method in ("dns", "web_server"):
        for i in range(5):
            ctx.run(["sleep", "10"], mutates=False)
            res_get = ecs_get("/domains/" + domain_name + "?clientId=" + str(client_id))
            if res_get.rc == 0:
                domain_details_raw = res_get.stdout
                break

    # Final fetch of domain details
    res_get = ecs_get("/domains/" + domain_name + "?clientId=" + str(client_id))
    if res_get.rc != 0:
        fail("Failed to fetch domain details after request: " + res_get.stderr)

    # Extract details for return data
    ov_eligible = _extract_json_bool(res_get.stdout, "ovEligible")
    ov_days_remaining = None
    ev_eligible = None
    ev_days_remaining = None

    ov_expiry = _extract_json_string(res_get.stdout, "ovExpiry")
    ev_expiry = _extract_json_string(res_get.stdout, "evExpiry")

    if ov_expiry != None:
        ov_days_remaining = _compute_days_remaining(ctx, ov_expiry)
    if ev_expiry != None:
        ev_days_remaining = _compute_days_remaining(ctx, ev_expiry)

    result = {
        "changed": True,
        "client_id": client_id,
        "domain_status": _extract_json_string(res_get.stdout, "verificationStatus"),
        "verification_method": verification_method,
    }

    if ov_eligible != None:
        result["ov_eligible"] = ov_eligible
    if ov_days_remaining != None:
        result["ov_days_remaining"] = ov_days_remaining
    if ev_eligible != None:
        result["ev_eligible"] = ev_eligible
    if ev_days_remaining != None:
        result["ev_days_remaining"] = ev_days_remaining

    if verification_method == "dns":
        dns_location = _extract_json_string(res_get.stdout, "dnsMethod.recordDomain")
        dns_contents = _extract_json_string(res_get.stdout, "dnsMethod.recordValue")
        dns_resource_type = _extract_json_string(res_get.stdout, "dnsMethod.recordType")
        result["dns_location"] = dns_location
        result["dns_contents"] = dns_contents
        result["dns_resource_type"] = dns_resource_type
    elif verification_method == "web_server":
        file_location = _extract_json_string(res_get.stdout, "webServerMethod.fileLocation")
        file_contents = _extract_json_string(res_get.stdout, "webServerMethod.fileContents")
        result["file_location"] = file_location
        result["file_contents"] = file_contents
    elif verification_method == "email":
        email = _extract_json_string(res_get.stdout, "emailMethod")
        if email != None:
            result["emails"] = [email]

    return {"changed": True, "msg": "requested domain validation or revalidation", "data": result}


def _extract_json_string(text, key):
    # Simple key extraction for top-level or one-level nested keys
    # Handles "key": "value" or nested "key": {"subkey": "value"}
    parts = key.split(".")
    if len(parts) == 1:
        search = '"' + parts[0] + '": "'
    else:
        search = '"' + parts[0] + '": {"' + parts[1] + '": "'
    idx = text.find(search)
    if idx == -1:
        return None
    idx = idx + len(search)
    end = text.find('"', idx)
    if end == -1:
        return None
    return text[idx:end]


def _extract_json_bool(text, key):
    search = '"' + key + '": '
    idx = text.find(search)
    if idx == -1:
        return None
    idx = idx + len(search)
    if text[idx:idx+4] == "true":
        return True
    if text[idx:idx+5] == "false":
        return False
    return None


def _compute_days_remaining(ctx, date_str):
    # date_str expected like "2025-12-31T23:59:59Z"
    # Use date command to compute diff in days
    formatted = date_str.replace("Z", "+0000")
    from_time = ctx.run(["date", "-u", "-d", formatted, "+%s"], mutates=False)
    now_time = ctx.run(["date", "-u", "+%s"], mutates=False)
    if from_time.rc != 0 or now_time.rc != 0:
        return None
    diff = int(from_time.stdout) - int(now_time.stdout)
    return int(diff / 86400)
