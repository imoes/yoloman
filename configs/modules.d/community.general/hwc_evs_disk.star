def main(ctx, params):
    state = params.get("state", "present")
    name = params["name"]
    availability_zone = params["availability_zone"]
    volume_type = params["volume_type"]
    domain = params["domain"]
    user = params["user"]
    password = params["password"]
    project = params["project"]
    identity_endpoint = params["identity_endpoint"]
    region = params.get("region")
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
    timeouts = params.get("timeouts", {})

    create_timeout = int((timeouts.get("create", "30m")).rstrip("m")) * 60
    delete_timeout = int((timeouts.get("delete", "30m")).rstrip("m")) * 60
    update_timeout = int((timeouts.get("update", "30m")).rstrip("m")) * 60

    auth_url = identity_endpoint + "/v3/auth/tokens"
    auth_body = {
        "auth": {
            "identity": {
                "methods": ["password"],
                "password": {
                    "user": {
                        "name": user,
                        "password": password,
                        "domain": {"name": domain}
                    }
                }
            },
            "scope": {
                "project": {"name": project},
                "domain": {"name": domain}
            }
        }
    }

    res = ctx.run(
        ["curl", "-s", "-X", "POST", auth_url, "-d", str(auth_body).replace("'", '"'), "-H", "Content-Type: application/json"],
        mutates=False
    )
    if res.rc != 0:
        fail("failed to authenticate: " + res.stderr)
    token = ""
    for line in res.stdout.split("\n"):
        if line.startswith("X-Subject-Token:"):
            token = line.split(": ")[1].strip()
            break
    if not token:
        fail("failed to extract authentication token")

    if not region:
        fail("region is required")
    endpoint_prefix = "evs." + region + ".myhuaweicloud.com"
    endpoint_v3 = "https://" + endpoint_prefix + "/v3/"
    endpoint_v2 = "https://" + endpoint_prefix + "/v2/"

    project_id_url = endpoint_v3 + "project?name=" + project
    res = ctx.run(
        ["curl", "-s", "-X", "GET", project_id_url, "-H", "X-Auth-Token: " + token],
        mutates=False
    )
    if res.rc != 0:
        fail("failed to get project_id: " + res.stderr)
    project_id = ""
    for line in res.stdout.split("\n"):
        if '"id":' in line:
            parts = line.split('"id": "')[1].split('"')[0]
            project_id = parts
            break
    if not project_id:
        fail("failed to parse project_id from response")

    base_url = endpoint_v3 + project_id + "/os-vendor-volumes"
    base_v2_url = endpoint_v2 + project_id + "/os-vendor-volumes"

    def find_disk_by_name():
        url = base_url + "?name=" + name
        res = ctx.run(
            ["curl", "-s", "-X", "GET", url, "-H", "X-Auth-Token: " + token],
            mutates=False
        )
        if res.rc != 0:
            return None
        for line in res.stdout.split("\n"):
            if '"id":' in line and '"name":' in line and name in line:
                parts = line.split('"id": "')[1].split('"')[0]
                return {"id": parts}
        return None

    def get_disk_details(disk_id):
        url = base_url + "/" + disk_id
        res = ctx.run(
            ["curl", "-s", "-X", "GET", url, "-H", "X-Auth-Token: " + token],
            mutates=False
        )
        if res.rc != 0:
            return None
        details = {}
        for line in res.stdout.split("\n"):
            if '"name":' in line:
                details["name"] = line.split('"name": "')[1].split('"')[0]
            elif '"id":' in line:
                details["id"] = line.split('"id": "')[1].split('"')[0]
            elif '"status":' in line:
                details["status"] = line.split('"status": "')[1].split('"')[0]
            elif '"availability_zone":' in line:
                details["availability_zone"] = line.split('"availability_zone": "')[1].split('"')[0]
            elif '"volume_type":' in line:
                details["volume_type"] = line.split('"volume_type": "')[1].split('"')[0]
            elif '"size":' in line:
                size_val = line.split('"size": ')[1].split(',')[0]
                details["size"] = int(size_val)
            elif '"description":' in line:
                desc = line.split('"description": "')[1].split('"')[0]
                if desc != "":
                    details["description"] = desc
            elif '"multiattach":' in line:
                mult = line.split('"multiattach": ')[1].split(',')[0]
                details["enable_share"] = mult == "true"
            elif '"bootable":' in line:
                boot = line.split('"bootable": ')[1].split(',')[0]
                details["is_bootable"] = boot == "true"
            elif '"created_at":' in line:
                details["created_at"] = line.split('"created_at": "')[1].split('"')[0]
        return details

    def build_metadata():
        meta = {}
        if encryption_id:
            meta["__system__cmkid"] = encryption_id
            meta["__system__encrypted"] = "1"
        if enable_full_clone:
            meta["full_clone"] = "0"
        if enable_scsi != None:
            meta["hw:passthrough"] = "true" if enable_scsi else "false"
        return meta

    def create_disk():
        data = {
            "volume": {
                "availability_zone": availability_zone,
                "name": name,
                "volume_type": volume_type,
            }
        }
        if size != None:
            data["volume"]["size"] = size
        if description:
            data["volume"]["description"] = description
        if enable_share != None:
            data["volume"]["multiattach"] = enable_share
        if backup_id:
            data["volume"]["backup_id"] = backup_id
        if snapshot_id:
            data["volume"]["snapshot_id"] = snapshot_id
        if image_id:
            data["volume"]["imageRef"] = image_id
        if enterprise_project_id:
            data["volume"]["enterprise_project_id"] = enterprise_project_id

        meta = build_metadata()
        if meta:
            data["volume"]["metadata"] = meta

        url = base_url
        body_str = str(data).replace("'", '"').replace("True", "true").replace("False", "false")
        res = ctx.run(
            ["curl", "-s", "-X", "POST", url, "-d", body_str, "-H", "X-Auth-Token: " + token, "-H", "Content-Type: application/json"],
            mutates=False
        )
        if res.rc != 0:
            fail("failed to create disk: " + res.stderr)

        job_url = ""
        for line in res.stdout.split("\n"):
            if '"job_id":' in line:
                job_url = line.split('"job_id": "')[1].split('"')[0]
                break

        if job_url:
            job_status_url = base_v2_url + "/jobs/" + job_url
            for i in range(create_timeout // 5):
                res = ctx.run(
                    ["curl", "-s", "-X", "GET", job_status_url, "-H", "X-Auth-Token: " + token],
                    mutates=False
                )
                if res.rc == 0 and '"status": "SUCCESS"' in res.stdout:
                    for line in res.stdout.split("\n"):
                        if '"volume_id":' in line:
                            return line.split('"volume_id": "')[1].split('"')[0]
                if i == (create_timeout // 5) - 1:
                    fail("timeout waiting for disk creation")
                # Sleep 5 seconds via loop to avoid import/time
                for _ in range(5 * 1000000):
                    pass
        return None

    def delete_disk(disk_id):
        url = base_url + "/" + disk_id
        res = ctx.run(
            ["curl", "-s", "-X", "DELETE", url, "-H", "X-Auth-Token: " + token],
            mutates=False
        )
        if res.rc != 0:
            fail("failed to delete disk: " + res.stderr)

        job_url = ""
        for line in res.stdout.split("\n"):
            if '"job_id":' in line:
                job_url = line.split('"job_id": "')[1].split('"')[0]
                break

        if job_url:
            job_status_url = base_v2_url + "/jobs/" + job_url
            for i in range(delete_timeout // 5):
                res = ctx.run(
                    ["curl", "-s", "-X", "GET", job_status_url, "-H", "X-Auth-Token: " + token],
                    mutates=False
                )
                if res.rc == 0 and '"status": "SUCCESS"' in res.stdout:
                    return True
                if i == (delete_timeout // 5) - 1:
                    fail("timeout waiting for disk deletion")
                for _ in range(5 * 1000000):
                    pass
        return True

    def update_disk(disk_id):
        updates = {}
        if description != None:
            updates["description"] = description
        if enable_share != None:
            updates["multiattach"] = enable_share

        if not updates:
            return False

        data = {"volume": updates}
        url = base_url + "/" + disk_id
        body_str = str(data).replace("'", '"').replace("True", "true").replace("False", "false")
        res = ctx.run(
            ["curl", "-s", "-X", "PUT", url, "-d", body_str, "-H", "X-Auth-Token: " + token, "-H", "Content-Type: application/json"],
            mutates=False
        )
        if res.rc != 0:
            fail("failed to update disk: " + res.stderr)
        return True

    def extend_disk(disk_id, new_size):
        if not new_size:
            return False
        data = {"os-extend": {"new_size": new_size}}
        url = base_url + "/" + disk_id + "/action"
        body_str = str(data).replace("'", '"').replace("True", "true").replace("False", "false")
        res = ctx.run(
            ["curl", "-s", "-X", "POST", url, "-d", body_str, "-H", "X-Auth-Token: " + token, "-H", "Content-Type: application/json"],
            mutates=False
        )
        if res.rc != 0:
            fail("failed to extend disk: " + res.stderr)

        job_url = ""
        for line in res.stdout.split("\n"):
            if '"job_id":' in line:
                job_url = line.split('"job_id": "')[1].split('"')[0]
                break

        if job_url:
            job_status_url = base_v2_url + "/jobs/" + job_url
            for i in range(update_timeout // 5):
                res = ctx.run(
                    ["curl", "-s", "-X", "GET", job_status_url, "-H", "X-Auth-Token: " + token],
                    mutates=False
                )
                if res.rc == 0 and '"status": "SUCCESS"' in res.stdout:
                    return True
                if i == (update_timeout // 5) - 1:
                    fail("timeout waiting for disk extension")
                for _ in range(5 * 1000000):
                    pass
        return True

    disk = find_disk_by_name()
    disk_id = disk["id"] if disk else None

    if state == "present":
        if disk_id:
            current = get_disk_details(disk_id)
            needs_update = False
            needs_extend = False
            new_size = None

            if description != None and current.get("description") != description:
                needs_update = True
            if enable_share != None and current.get("enable_share") != enable_share:
                needs_update = True
            if size != None and current.get("size") and current["size"] < size:
                needs_extend = True
                new_size = size

            changed = needs_update or needs_extend
            if changed:
                if ctx.check_mode:
                    return {"changed": True, "msg": "would update or extend disk"}

                if needs_update:
                    update_disk(disk_id)
                if needs_extend:
                    extend_disk(disk_id, new_size)

                updated = get_disk_details(disk_id)
                if (description != None and updated.get("description") != description) or \
                   (enable_share != None and updated.get("enable_share") != enable_share) or \
                   (size != None and updated.get("size") != size):
                    fail("disk update/extend failed to apply")
            return {"changed": changed, "msg": "disk already exists or updated", "id": disk_id}

        else:
            if ctx.check_mode:
                return {"changed": True, "msg": "would create disk"}
            disk_id = create_disk()
            if not disk_id:
                fail("disk creation failed — no disk ID returned")
            return {"changed": True, "msg": "disk created", "id": disk_id}

    elif state == "absent":
        if disk_id:
            if ctx.check_mode:
                return {"changed": True, "msg": "would delete disk"}
            delete_disk(disk_id)
            return {"changed": True, "msg": "disk deleted"}
        return {"changed": False, "msg": "disk not found"}

    fail("unsupported state: " + state)
