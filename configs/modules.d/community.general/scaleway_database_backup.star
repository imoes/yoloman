def main(ctx, params):
    state = params.get("state", "present")
    region = params["region"]
    api_token = params["api_token"]
    api_url = params.get("api_url", "https://api.scaleway.com")
    api_timeout = params.get("api_timeout", 30)
    validate_certs = params.get("validate_certs", True)
    wait = params.get("wait", False)
    wait_timeout = params.get("wait_timeout", 300)
    wait_sleep_time = params.get("wait_sleep_time", 3)

    id = params.get("id")
    name = params.get("name")
    database_name = params.get("database_name")
    instance_id = params.get("instance_id")
    expires_at = params.get("expires_at")

    # Required checks per state
    if state == "present":
        if name == None or database_name == None or instance_id == None:
            fail("state=present requires name, database_name, and instance_id")
    elif state in ("absent", "exported", "restored"):
        if id == None:
            fail("state=%s requires id" % state)
    elif state == "restored":
        if database_name == None or instance_id == None:
            fail("state=restored requires database_name and instance_id")

    # Helper to call Scaleway API
    def api_call(method, path, payload=None):
        url = "%s/rdb/v1/regions/%s%s" % (api_url, region, path)
        if method in ("POST", "PATCH") and payload != None:
            payload_str = ctx.jsonify(payload)
            res = ctx.run(
                ["curl", "-sS", "-X", method, "-H", "Authorization: Bearer " + api_token, "-H", "Content-Type: application/json", "--max-time", str(api_timeout), "-d", payload_str],
                mutates=True,
            )
        else:
            res = ctx.run(
                ["curl", "-sS", "-X", method, "-H", "Authorization: Bearer " + api_token, "-H", "Content-Type: application/json", "--max-time", str(api_timeout)],
                mutates=False,
            )
        if res.rc != 0:
            fail("API request failed: %s %s, rc=%d, stderr=%s" % (method, url, res.rc, res.stderr))
        return ctx.json_loads(res.stdout)

    # Get backup by ID
    def get_backup(backup_id):
        res = ctx.run([
            "curl", "-sS", "-X", "GET",
            "-H", "Authorization: Bearer " + api_token,
            "-H", "Content-Type: application/json",
            "--max-time", str(api_timeout),
            "%s/rdb/v1/regions/%s/backups/%s" % (api_url, region, backup_id)
        ])
        if res.rc == 0:
            return ctx.json_loads(res.stdout)
        if res.rc == 404:
            return None
        fail("Failed to get backup %s: rc=%d, stderr=%s" % (backup_id, res.rc, res.stderr))

    # Wait for backup state to reach stable state (ready or deleting)
    stable_states = ["ready", "deleting"]
    def wait_for_backup(backup):
        if not wait:
            return backup
        if backup["status"] in stable_states:
            return backup
        end_time = ctx.time() + wait_timeout
        while ctx.time() < end_time:
            current = get_backup(backup["id"])
            if current == None:
                fail("Backup disappeared while waiting")
            if current["status"] in stable_states:
                return current
            ctx.sleep(wait_sleep_time)
        fail("Backup %s did not reach stable state within %d seconds" % (backup["id"], wait_timeout))

    # Present strategy
    def present_strategy(backup):
        if backup != None:
            # Check if update is needed
            need_update = False
            if name != None and name != backup.get("name"):
                need_update = True
            if expires_at != None and expires_at != backup.get("expires_at"):
                need_update = True
            if not need_update:
                return {"changed": False, "metadata": backup}

            if ctx.check_mode:
                return {"changed": True, "msg": "would update backup %s" % id}

            payload = {}
            if name != None:
                payload["name"] = name
            if expires_at != None:
                payload["expires_at"] = expires_at
            updated = api_call("PATCH", "/backups/%s" % backup["id"], payload)
            result = wait_for_backup(updated)
            return {"changed": True, "metadata": result}

        # Create new backup
        if ctx.check_mode:
            return {"changed": True, "msg": "would create backup"}

        payload = {
            "name": name,
            "database_name": database_name,
            "instance_id": instance_id,
        }
        if expires_at != None:
            payload["expires_at"] = expires_at

        created = api_call("POST", "/backups", payload)
        result = wait_for_backup(created)
        return {"changed": True, "metadata": result}

    # Absent strategy
    def absent_strategy(backup):
        if backup == None:
            return {"changed": False, "metadata": {}}
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete backup %s" % id}
        api_call("DELETE", "/backups/%s" % id, {})
        # Wait for deletion to complete
        wait_for_backup(backup)
        return {"changed": True, "metadata": {}}

    # Exported strategy
    def exported_strategy(backup):
        if backup == None:
            fail("Backup %s not found" % id)
        if backup.get("download_url") != None:
            return {"changed": False, "metadata": backup}
        if ctx.check_mode:
            return {"changed": True, "msg": "would export backup %s" % id}
        wait_for_backup(backup)
        exported = api_call("POST", "/backups/%s/export" % id, {})
        result = wait_for_backup(exported)
        return {"changed": True, "metadata": result}

    # Restored strategy
    def restored_strategy(backup):
        if backup == None:
            fail("Backup %s not found" % id)
        if ctx.check_mode:
            return {"changed": True, "msg": "would restore backup %s" % id}
        wait_for_backup(backup)
        payload = {
            "database_name": database_name,
            "instance_id": instance_id,
        }
        restored = api_call("POST", "/backups/%s/restore" % id, payload)
        result = wait_for_backup(restored)
        return {"changed": True, "metadata": result}

    # Get backup by ID if provided
    backup_by_id = None
    if id != None:
        backup_by_id = get_backup(id)

    # Dispatch to strategy
    if state == "present":
        return present_strategy(backup_by_id)
    elif state == "absent":
        return absent_strategy(backup_by_id)
    elif state == "exported":
        return exported_strategy(backup_by_id)
    elif state == "restored":
        return restored_strategy(backup_by_id)
    else:
        fail("Unsupported state: %s" % state)
