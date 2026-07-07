def main(ctx, params):
    host = params["host"]
    state = params.get("state", "present")
    username = params["username"]
    password = params["password"]
    endpoints = params["endpoints"]
    cluster = params.get("cluster")
    domain = params.get("domain")
    iscsi_chap_name = params.get("iscsi_chap_name")
    iscsi_chap_secret = params.get("iscsi_chap_secret")

    # Build command base
    cmd = [
        "svcinfo", "lshost", "-host", host,
        "-fmt", "csv", "-noheadings"
    ]

    # Probe current state (read-only)
    res = ctx.run(["sshpass", "-p", password, "ssh", "-o", "StrictHostKeyChecking=no",
                   username + "@" + endpoints] + cmd, mutates=False)
    if res.rc != 0:
        fail("failed to list hosts: " + res.stderr)

    host_exists = res.stdout.strip() != ""

    if state == "present":
        if host_exists:
            # Check if update is needed (cluster/domain/chap fields)
            parts = res.stdout.strip().split(",")
            if len(parts) < 7:
                fail("unexpected host list output format")

            current_cluster = parts[5].strip().strip('"') if len(parts) > 5 else ""
            current_domains = parts[6].strip().strip('"') if len(parts) > 6 else ""
            current_chap_name = parts[2].strip().strip('"') if len(parts) > 2 else ""
            current_chap_secret = parts[3].strip().strip('"') if len(parts) > 3 else ""

            updates = []
            if cluster and cluster != current_cluster:
                updates.append("cluster=" + cluster)
            if domain and domain != current_domains:
                updates.append("domain=" + domain)
            if iscsi_chap_name and iscsi_chap_name != current_chap_name:
                updates.append("iscsi_chap_name=" + iscsi_chap_name)
            if iscsi_chap_secret and iscsi_chap_secret != current_chap_secret:
                updates.append("iscsi_chap_secret=****")

            # If no updates needed, return unchanged
            if not updates:
                return {"changed": False, "msg": "host " + host + " already exists with desired configuration"}

            # Update host (only if check_mode, skip mutation)
            update_cmd = [
                "svcconfig", "chhost", "-host", host
            ] + updates
            res = ctx.run(["sshpass", "-p", password, "ssh", "-o", "StrictHostKeyChecking=no",
                           username + "@" + endpoints] + update_cmd, mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would update host " + host}
            if res.rc != 0:
                fail("failed to update host " + host + ": " + res.stderr)
            return {"changed": True, "msg": "updated host " + host}

        # Create host if not exists
        create_cmd = [
            "svcconfig", "mkrhost", "-host", host
        ]
        if cluster:
            create_cmd.extend(["-cluster", cluster])
        if domain:
            create_cmd.extend(["-domain", domain])
        if iscsi_chap_name:
            create_cmd.extend(["-iscsi_chap_name", iscsi_chap_name])
        if iscsi_chap_secret:
            create_cmd.extend(["-iscsi_chap_secret", iscsi_chap_secret])

        res = ctx.run(["sshpass", "-p", password, "ssh", "-o", "StrictHostKeyChecking=no",
                       username + "@" + endpoints] + create_cmd, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would create host " + host}
        if res.rc != 0:
            fail("failed to create host " + host + ": " + res.stderr)
        return {"changed": True, "msg": "created host " + host}

    elif state == "absent":
        if not host_exists:
            return {"changed": False, "msg": "host " + host + " does not exist"}
        res = ctx.run(["sshpass", "-p", password, "ssh", "-o", "StrictHostKeyChecking=no",
                       username + "@" + endpoints,
                       "svcconfig", "rmhost", "-host", host], mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would delete host " + host}
        if res.rc != 0:
            fail("failed to delete host " + host + ": " + res.stderr)
        return {"changed": True, "msg": "deleted host " + host}

    fail("unsupported state: " + state)
