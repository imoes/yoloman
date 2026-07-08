def main(ctx, params):
    # Required parameters
    availability_zone = params["availability_zone"]
    domain = params["domain"]
    identity_endpoint = params["identity_endpoint"]
    name = params["name"]
    password = params["password"]
    project = params["project"]
    user = params["user"]
    volume_type = params["volume_type"]

    # Optional parameters
    state = params.get("state", "present")
    backup_id = params.get("backup_id")
    description = params.get("description")
    enable_full_clone = params.get("enable_full_clone")
    enable_scsi = params.get("enable_scsi")
    enable_share = params.get("enable_share")
    encryption_id = params.get("encryption_id")
    enterprise_project_id = params.get("enterprise_project_id")
    image_id = params.get("image_id")
    size = params.get("size")
    snapshot_id = params.get("snapshot_id")
    region = params.get("region")

    # Default timeouts (parse minutes to seconds)
    timeouts = params.get("timeouts", {})
    create_timeout = timeouts.get("create", "30m")
    delete_timeout = timeouts.get("delete", "30m")
    update_timeout = timeouts.get("update", "30m")

    # Parse timeout minutes to seconds
    def parse_timeout(t):
        if not t.endswith("m"):
            fail("timeout must end with 'm', got: " + t)
        return 60 * int(t[:-1])

    create_secs = parse_timeout(create_timeout)
    delete_secs = parse_timeout(delete_timeout)
    update_secs = parse_timeout(update_timeout)

    # Build auth endpoint and project scope
    auth_url = identity_endpoint.rstrip("/") + "/v3/auth/tokens"
    scope = {
        "project": {"name": project},
        "domain": {"name": domain}
    }

    # Get token via curl (no Python stdlib)
    def get_token():
        cmd = [
            "curl", "-s", "-k", "-X", "POST", auth_url,
            "-H", "Content-Type: application/json",
            "-d", '{"auth":{"identity":{"methods":["password"],"password":{"user":{"name":"%s","password":"%s","domain":{"name":"%s"}}}},"scope":%s}}' % (
                user, password, domain, str(scope).replace("'", '"'))
        ]
        if region:
            cmd.extend(["-H", "X-Region-Name:" + region])
        res = ctx.run(cmd, ok_codes=[0, 1])
        if res.rc != 0:
            fail("failed to authenticate: " + res.stderr)
        # Extract X-Subject-Token from response headers using grep
        token_cmd = ["echo", res.stdout]
        token_res = ctx.run(token_cmd, ok_codes=[0])
        # Use simple header extraction: look for 'X-Subject-Token:' in output
        lines = token_res.stdout.splitlines()
        token = None
        for line in lines:
            if line.startswith("X-Subject-Token:"):
                token = line.split(":", 1)[1].strip()
                break
        if token == None:
            fail("failed to extract auth token from response")
        return token

    token = get_token()
    # Determine base URL from identity_endpoint and strip trailing /v3
    base_url = identity_endpoint.rstrip("/").replace("/v3", "")
    volume_base = base_url + "/v3/" + project + "/cloudvolumes"

    # Search for existing disk by name and AZ
    def search_disk():
        # Use os-vendor-volumes for vendor-specific search
        list_url = base_url + "/v3/" + project + "/os-vendor-volumes/detail"
        # Build query parameters
        params_list = []
        if enable_share != None:
            params_list.append("multiattach=" + ("true" if enable_share else "false"))
        if name:
            params_list.append("name=" + name)
        if availability_zone:
            params_list.append("availability_zone=" + availability_zone)
        if params_list:
            list_url += "?" + "&".join(params_list) + "&limit=10&offset=0"

        # Pagination (simple: only one page due to limit=10)
        res = ctx.run(["curl", "-s", "-k", "-X", "GET", list_url,
                       "-H", "Content-Type: application/json",
                       "-H", "X-Auth-Token:" + token], ok_codes=[0, 1])
        if res.rc != 0:
            fail("failed to list disks: " + res.stderr)

        # Parse JSON manually (no json module)
        # Extract 'volumes' array and search for name match
        out = res.stdout.strip()
        if not out.startswith("{") or not out.endswith("}"):
            fail("invalid JSON response")
        # Extract volumes list using simple string search
        volumes_start = out.find('"volumes"')
        if volumes_start == -1:
            return []
        # Find array start after 'volumes":'
        arr_start = out.find("[", volumes_start)
        if arr_start == -1:
            return []
        # Find array end
        depth = 0
        arr_end = arr_start
        for i in range(arr_start, len(out)):
            if out[i] == '[':
                depth += 1
            elif out[i] == ']':
                depth -= 1
                if depth == 0:
                    arr_end = i + 1
                    break

        arr_str = out[arr_start:arr_end]
        # Split into objects (naive approach for small lists)
        # Find objects by '{' and '}'
        objects = []
        brace_depth = 0
        current = ""
        for c in arr_str:
            if c == '{':
                brace_depth += 1
                current += c
            elif c == '}':
                brace_depth -= 1
                current += c
                if brace_depth == 0:
                    objects.append(current.strip())
                    current = ""
            elif brace_depth > 0:
                current += c
        disks = []
        for obj in objects:
            # Extract name and id
            name_start = obj.find('"name"')
            if name_start == -1:
                continue
            # Find string value after "name":
            q1 = obj.find('"', name_start + 6)
            if q1 == -1:
                continue
            q2 = obj.find('"', q1 + 1)
            if q2 == -1:
                continue
            obj_name = obj[q1 + 1:q2]

            id_start = obj.find('"id"')
            if id_start == -1:
                continue
            id_q1 = obj.find('"', id_start + 4)
            if id_q1 == -1:
                continue
            id_q2 = obj.find('"', id_q1 + 1)
            if id_q2 == -1:
                continue
            obj_id = obj[id_q1 + 1:id_q2]

            # Check for name match
            if obj_name == name:
                disks.append({"id": obj_id})

        return disks

    # Get disk info by ID
    def get_disk_info(disk_id):
        url = volume_base + "/" + disk_id
        res = ctx.run(["curl", "-s", "-k", "-X", "GET", url,
                       "-H", "Content-Type: application/json",
                       "-H", "X-Auth-Token:" + token], ok_codes=[0, 1])
        if res.rc != 0:
            fail("failed to get disk info: " + res.stderr)
        return res.stdout

    # Build create body
    def build_create_body():
        body = {"volume": {}}
        body["volume"]["availability_zone"] = availability_zone
        body["volume"]["name"] = name
        body["volume"]["volume_type"] = volume_type

        if backup_id:
            body["volume"]["backup_id"] = backup_id
        if description:
            body["volume"]["description"] = description
        if enable_share != None:
            body["volume"]["multiattach"] = ("true" if enable_share else "false")
        if encryption_id:
            body["volume"]["metadata"] = {
                "__system__cmkid": encryption_id,
                "__system__encrypted": "1"
            }
        if image_id:
            body["volume"]["imageRef"] = image_id
        if size != None:
            body["volume"]["size"] = size
        if snapshot_id:
            body["volume"]["snapshot_id"] = snapshot_id
        if enable_scsi != None:
            if not "metadata" in body["volume"]:
                body["volume"]["metadata"] = {}
            body["volume"]["metadata"]["hw:passthrough"] = ("true" if enable_scsi else "false")
        if enable_full_clone != None:
            if not "metadata" in body["volume"]:
                body["volume"]["metadata"] = {}
            body["volume"]["metadata"]["full_clone"] = ("0" if enable_full_clone else "")
        if enterprise_project_id:
            body["volume"]["enterprise_project_id"] = enterprise_project_id

        return str(body).replace("'", '"').replace("None", "null")

    # Wait for job completion
    def wait_for_job(job_id):
        end_time = ctx.time() + create_secs
        while ctx.time() < end_time:
            url = base_url + "/v1/" + project + "/jobs/" + job_id
            res = ctx.run(["curl", "-s", "-k", "-X", "GET", url,
                           "-H", "Content-Type: application/json",
                           "-H", "X-Auth-Token:" + token], ok_codes=[0, 1])
            if res.rc != 0:
                fail("failed to get job status: " + res.stderr)
            # Check status
            status_start = res.stdout.find('"status"')
            if status_start != -1:
                status_q1 = res.stdout.find('"', status_start + 8)
                if status_q1 != -1:
                    status_q2 = res.stdout.find('"', status_q1 + 1)
                    if status_q2 != -1:
                        status = res.stdout[status_q1 + 1:status_q2]
                        if status == "SUCCESS":
                            # Extract volume_id
                            vol_start = res.stdout.find('"volume_id"')
                            if vol_start != -1:
                                vol_q1 = res.stdout.find('"', vol_start + 11)
                                if vol_q1 != -1:
                                    vol_q2 = res.stdout.find('"', vol_q1 + 1)
                                    if vol_q2 != -1:
                                        return res.stdout[vol_q1 + 1:vol_q2]
            ctx.sleep(1)  # Simulate sleep
        fail("timeout waiting for job completion")

    # Delete disk
    def delete_disk(disk_id):
        url = volume_base + "/" + disk_id
        res = ctx.run(["curl", "-s", "-k", "-X", "DELETE", url,
                       "-H", "Content-Type: application/json",
                       "-H", "X-Auth-Token:" + token], ok_codes=[0, 1])
        if res.rc != 0:
            fail("failed to delete disk: " + res.stderr)
        # Parse response for job ID if async
        if '"job_id"' in res.stdout:
            job_start = res.stdout.find('"job_id"')
            job_q1 = res.stdout.find('"', job_start + 8)
            job_q2 = res.stdout.find('"', job_q1 + 1)
            job_id = res.stdout[job_q1 + 1:job_q2]
            wait_for_job(job_id)

    # Main logic
    if state == "present":
        # Search for existing disk
        existing = search_disk()
        disk_id = None
        if len(existing) > 0:
            if len(existing) > 1:
                fail("found multiple disks with the same name in the same AZ")
            disk_id = existing[0]["id"]
            # In check_mode, just report existing state
            if ctx.check_mode:
                info = get_disk_info(disk_id)
                # Parse disk info to extract size, type, etc.
                # For simplicity, return minimal changed=True
                return {"changed": False, "msg": "disk already exists", "id": disk_id}

        # If no existing disk, create
        if disk_id == None:
            if ctx.check_mode:
                return {"changed": True, "msg": "would create disk " + name}

            # Create request
            body = build_create_body()
            res = ctx.run(["curl", "-s", "-k", "-X", "POST", volume_base,
                           "-H", "Content-Type: application/json",
                           "-H", "X-Auth-Token:" + token,
                           "-d", body], ok_codes=[0, 1])
            if res.rc != 0:
                fail("failed to create disk: " + res.stderr)

            # Extract job_id
            if '"job_id"' in res.stdout:
                job_start = res.stdout.find('"job_id"')
                job_q1 = res.stdout.find('"', job_start + 8)
                job_q2 = res.stdout.find('"', job_q1 + 1)
                job_id = res.stdout[job_q1 + 1:job_q2]
                disk_id = wait_for_job(job_id)
            else:
                # Direct response (no job)
                id_start = res.stdout.find('"id"')
                if id_start != -1:
                    id_q1 = res.stdout.find('"', id_start + 3)
                    id_q2 = res.stdout.find('"', id_q1 + 1)
                    disk_id = res.stdout[id_q1 + 1:id_q2]
                else:
                    fail("failed to extract disk ID from response")

            return {"changed": True, "msg": "disk created", "id": disk_id}

        # Disk exists, check for updates (simplified: only name/description changes)
        info = get_disk_info(disk_id)
        # Check for changes (name/description)
        update_needed = False
        if description and '"description"' in info:
            desc_start = info.find('"description"')
            desc_q1 = info.find('"', desc_start + 13)
            desc_q2 = info.find('"', desc_q1 + 1)
            current_desc = info[desc_q1 + 1:desc_q2]
            if current_desc != description:
                update_needed = True

        if update_needed:
            if ctx.check_mode:
                return {"changed": True, "msg": "would update disk " + name}

            # Update disk (simplified: name/description only)
            update_body = '{"volume":{}}'
            if description:
                update_body = '{"volume":{"description":"%s"}}' % description
            url = volume_base + "/" + disk_id
            res = ctx.run(["curl", "-s", "-k", "-X", "PUT", url,
                           "-H", "Content-Type: application/json",
                           "-H", "X-Auth-Token:" + token,
                           "-d", update_body], ok_codes=[0, 1])
            if res.rc != 0:
                fail("failed to update disk: " + res.stderr)
            return {"changed": True, "msg": "disk updated", "id": disk_id}

        return {"changed": False, "msg": "disk already exists", "id": disk_id}

    else:  # absent
        # Search for disk
        existing = search_disk()
        if len(existing) == 0:
            return {"changed": False, "msg": "disk not found"}

        disk_id = existing[0]["id"]
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete disk " + name}

        delete_disk(disk_id)
        return {"changed": True, "msg": "disk deleted"}
