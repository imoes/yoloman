def main(ctx, params):
    # Required params
    compute_id = params["compute_id"]
    private_network_id = params["private_network_id"]
    project = params["project"]
    region = params["region"]
    state = params.get("state", "present")
    api_token = params["api_token"]
    api_url = params.get("api_url", "https://api.scaleway.com")
    timeout = params.get("api_timeout", 30)
    validate_certs = params.get("validate_certs", True)

    # Normalize region: handle aliases (ams1/EMEA-NL-EVS, par1/EMEA-FR-PAR1, etc.)
    region_map = {
        "ams1": "ams1",
        "EMEA-NL-EVS": "ams1",
        "par1": "par1",
        "EMEA-FR-PAR1": "par1",
        "par2": "par2",
        "EMEA-FR-PAR2": "par2",
        "waw1": "waw1",
        "EMEA-PL-WAW1": "waw1"
    }
    if region not in region_map:
        fail("unsupported region: " + region)
    region = region_map[region]

    # Base URL for the region
    base_url = api_url.rstrip("/") + "/" + region

    # Helper: make HTTP request
    def http(method, path, data_dict=None):
        url = base_url + "/" + path
        if method == "GET":
            res = ctx.run(
                ["curl", "-s", "-w", "%{http_code}", "-X", "GET", url] +
                (["--cacert", "/etc/ssl/certs/ca-certificates.crt"] if validate_certs else ["--insecure"]) +
                ["-H", "Authorization: Bearer " + api_token] +
                ["-H", "Content-Type: application/json"],
                mutates=False
            )
        else:
            if data_dict == None:
                data = ""
            else:
                data = str(data_dict)
            res = ctx.run(
                ["curl", "-s", "-w", "%{http_code}", "-X", method.upper(), url] +
                (["-d", data] if data_dict != None else []) +
                (["--cacert", "/etc/ssl/certs/ca-certificates.crt"] if validate_certs else ["--insecure"]) +
                ["-H", "Authorization: Bearer " + api_token] +
                (["-H", "Content-Type: application/json"] if data_dict != None else []),
                mutates=True
            )
        if res.skipped:
            return {"skipped": True, "rc": 0, "stdout": "", "stderr": ""}
        if res.rc != 0:
            fail("HTTP request failed: " + res.stderr)
        # Extract last line as http_code (last 3 chars)
        lines = res.stdout.strip().split("\n")
        code_str = lines[-1]
        if not code_str.isdigit() or len(code_str) != 3:
            fail("HTTP code parsing error: " + code_str)
        code = int(code_str)
        body = "\n".join(lines[:-1])
        return {"rc": code, "body": body}

    # Helper: get NICs for the instance
    def get_nics():
        res = http("GET", "servers/" + compute_id + "/private_nics")
        if res.get("skipped"):
            return {"skipped": True}
        if res["rc"] != 200:
            fail("Failed to get private_nics: " + res["body"])
        body = res["body"]
        # Parse JSON manually
        start_idx = body.find('"private_nics"')
        if start_idx == -1:
            return []
        bracket_start = body.find("[", start_idx)
        if bracket_start == -1:
            return []
        # Find matching ]
        depth = 0
        i = bracket_start
        while i < len(body) and depth >= 0:
            if body[i] == "[":
                depth += 1
            elif body[i] == "]":
                depth -= 1
            i += 1
        if depth != 0:
            fail("Failed to parse private_nics JSON")
        arr_str = body[bracket_start:i]
        # Handle empty array
        if arr_str == "[]":
            return []
        # Extract content between [ and ]
        inner = arr_str[1:-1].strip()
        if inner == "":
            return []
        # Split objects by "}, {"
        # Replace "}, {" with "}|{"
        inner = inner.replace("}, {", "}|{")
        items = []
        for seg in inner.split("|"):
            seg = seg.strip()
            if seg == "":
                continue
            # Extract private_network_id
            pn_id_start = seg.find('"private_network_id"')
            if pn_id_start == -1:
                continue
            pn_id_start = seg.find(':', pn_id_start)
            if pn_id_start == -1:
                continue
            pn_id_start += 1
            while pn_id_start < len(seg) and seg[pn_id_start] in " \t\"":
                pn_id_start += 1
            pn_id_end = pn_id_start
            while pn_id_end < len(seg) and seg[pn_id_end] not in "\"},\n":
                pn_id_end += 1
            nid = seg[pn_id_start:pn_id_end]
            if nid == private_network_id:
                items.append(seg)
        if len(items) == 0:
            return []
        # Extract id from first matching item
        nic_str = items[0]
        id_start = nic_str.find('"id"')
        if id_start == -1:
            fail("Cannot extract id from nic")
        id_start = nic_str.find(':', id_start)
        if id_start == -1:
            fail("Cannot extract id from nic")
        id_start += 1
        while id_start < len(nic_str) and nic_str[id_start] in " \t\"":
            id_start += 1
        id_end = id_start
        while id_end < len(nic_str) and nic_str[id_end] not in "\"},\n":
            id_end += 1
        nic_id = nic_str[id_start:id_end]
        return {"id": nic_id}

    # Check if NIC already attached
    nics = get_nics()
    if state == "present":
        # Check if already attached
        if isinstance(nics, dict) and nics.get("id") != None and nics.get("id") != "":
            return {"changed": False, "msg": "private network already attached", "data": {"scaleway_compute_private_network": {}}}

        # Add NIC
        data_dict = {"private_network_id": private_network_id}
        if ctx.check_mode:
            return {"changed": True, "msg": "would add private network to compute instance", "data": {"scaleway_compute_private_network": {"status": "a private network would be added to a server"}}}

        res = http("POST", "servers/" + compute_id + "/private_nics", data_dict)
        if res.get("skipped"):
            return {"changed": True, "msg": "would add private network to compute instance", "data": {"scaleway_compute_private_network": {"status": "a private network would be added to a server"}}}
        if res["rc"] != 200 and res["rc"] != 201:
            fail("Error adding private network: " + res["body"])

        return {"changed": True, "msg": "added private network to compute instance", "data": {"scaleway_compute_private_network": {}}}

    elif state == "absent":
        # Check if attached
        if isinstance(nics, dict) and (nics.get("id") == None or nics.get("id") == ""):
            return {"changed": False, "msg": "private network not attached", "data": {"scaleway_compute_private_network": {}}}

        nic_id = nics["id"]
        # Delete
        if ctx.check_mode:
            return {"changed": True, "msg": "would remove private network from compute instance", "data": {"scaleway_compute_private_network": {"status": "private network would be removed"}}}

        res = http("DELETE", "servers/" + compute_id + "/private_nics/" + nic_id)
        if res.get("skipped"):
            return {"changed": True, "msg": "would remove private network from compute instance", "data": {"scaleway_compute_private_network": {"status": "private network would be removed"}}}
        if res["rc"] != 200 and res["rc"] != 204:
            fail("Error removing private network: " + res["body"])

        return {"changed": True, "msg": "removed private network from compute instance", "data": {"scaleway_compute_private_network": {}}}

    else:
        fail("Unsupported state: " + state)
