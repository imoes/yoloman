def main(ctx, params):
    name = params.get("name")
    state = params.get("state", "present")
    email = params.get("email")
    ttl = params.get("ttl", 3600)
    comment = params.get("comment")

    # Required for domain creation
    if state == "present" and email == None:
        fail('An "email" attribute is required for creating a domain')
    if name == None:
        fail("name is required")

    # Rackspace DNS interaction simulation via run() calls
    # Since pyrax isn't available in Starlark, use the rax CLI if available
    # Otherwise fail with a clear message
    if not ctx.file_exists("/usr/bin/rax"):
        fail("Rackspace CLI (rax) not found; this module requires the rax CLI tool installed and in PATH")

    rax_cmd = ["/usr/bin/rax"]
    changed = False
    domain = None

    if state == "present":
        # Check if domain exists
        list_res = ctx.run(rax_cmd + ["dns", "domains", "list", "--format", "json"])
        if list_res.rc != 0:
            fail("Failed to list domains: " + list_res.stderr)

        # Simple JSON parsing for list of dicts with name field
        # Expected format: [{"id": "...", "name": "example.com", ...}, ...]
        lines = list_res.stdout.split("\n")
        domains = []
        current = {}
        for line in lines:
            line = line.strip()
            if line.startswith('"id"'):
                # Extract id
                parts = line.split('"')
                if len(parts) >= 4:
                    current["id"] = parts[3]
            elif line.startswith('"name"'):
                parts = line.split('"')
                if len(parts) >= 4:
                    current["name"] = parts[3]
            elif line.startswith('"emailAddress"'):
                parts = line.split('"')
                if len(parts) >= 4:
                    current["emailAddress"] = parts[3]
            elif line.startswith('"ttl"'):
                parts = line.split('"')
                if len(parts) >= 4:
                    val = parts[3]
                    if val.isdigit() or (val.startswith('-') and val[1:].isdigit()):
                        current["ttl"] = int(val)
                    else:
                        current["ttl"] = 3600
            elif line.startswith('"comment"'):
                parts = line.split('"')
                if len(parts) >= 4:
                    current["comment"] = parts[3]
            elif line.startswith("}") and len(current) > 0:
                domains.append(current)
                current = {}

        for d in domains:
            if d.get("name") == name:
                domain = d
                break

        if domain == None:
            # Create domain
            create_cmd = rax_cmd + [
                "dns", "domains", "create",
                "--name", name,
                "--email", email,
                "--ttl", str(ttl),
            ]
            if comment != None:
                create_cmd += ["--comment", comment]

            create_res = ctx.run(create_cmd, mutates=True)
            if create_res.skipped:
                return {"changed": True, "msg": "would create domain " + name}
            if create_res.rc != 0:
                fail("Failed to create domain " + name + ": " + create_res.stderr)
            changed = True
            domain = {"name": name, "id": "", "ttl": ttl, "emailAddress": email}
            if comment != None:
                domain["comment"] = comment
        else:
            # Update if needed
            update_needed = False
            update_cmd = rax_cmd + ["dns", "domains", "update", domain["id"]]

            # Check email
            if domain.get("emailAddress") != email:
                update_needed = True
                update_cmd += ["--email", email]

            # Check ttl
            if str(domain.get("ttl")) != str(ttl):
                update_needed = True
                update_cmd += ["--ttl", str(ttl)]

            # Check comment
            if domain.get("comment") != comment:
                update_needed = True
                update_cmd += ["--comment", comment if comment != None else ""]

            if update_needed:
                update_res = ctx.run(update_cmd, mutates=True)
                if update_res.skipped:
                    return {"changed": True, "msg": "would update domain " + name}
                if update_res.rc != 0:
                    fail("Failed to update domain " + name + ": " + update_res.stderr)
                changed = True

        return {"changed": changed, "msg": "domain " + name + " is " + state, "domain": domain}

    elif state == "absent":
        # Check if domain exists
        list_res = ctx.run(rax_cmd + ["dns", "domains", "list", "--format", "json"])
        if list_res.rc != 0:
            fail("Failed to list domains: " + list_res.stderr)

        lines = list_res.stdout.split("\n")
        domains = []
        current = {}
        for line in lines:
            line = line.strip()
            if line.startswith('"id"'):
                parts = line.split('"')
                if len(parts) >= 4:
                    current["id"] = parts[3]
            elif line.startswith('"name"'):
                parts = line.split('"')
                if len(parts) >= 4:
                    current["name"] = parts[3]
            elif line.startswith("}") and len(current) > 0:
                domains.append(current)
                current = {}

        found = None
        for d in domains:
            if d.get("name") == name:
                found = d
                break

        if found != None:
            # Delete domain
            delete_res = ctx.run(rax_cmd + ["dns", "domains", "delete", found["id"]], mutates=True)
            if delete_res.skipped:
                return {"changed": True, "msg": "would delete domain " + name}
            if delete_res.rc != 0:
                fail("Failed to delete domain " + name + ": " + delete_res.stderr)
            changed = True

        return {"changed": changed, "msg": "domain " + name + " is " + state}
    else:
        fail("Unsupported state: " + state)
