def main(ctx, params):
    # Extract required parameters
    project = params["project"]
    state = params.get("state", "present")
    link_url = params["link_url"]
    image_url = params["image_url"]

    # Build API endpoint for project badges
    base_url = params.get("api_url", "https://gitlab.com")
    if base_url.endswith("/"):
        base_url = base_url.rstrip("/")

    # Determine auth header
    api_token = params.get("api_token") or params.get("api_oauth_token") or params.get("api_job_token")
    api_username = params.get("api_username")
    api_password = params.get("api_password")

    headers = {"Content-Type": "application/json"}
    if api_token:
        headers["PRIVATE-TOKEN"] = api_token
    elif api_username and api_password:
        # Build basic auth header manually (no base64 module available)
        tbl = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        def b64_encode(s):
            bits = ""
            for c in s:
                bits += format(ord(c), '08b')
            out = ""
            for i in range(0, len(bits), 6):
                chunk = bits[i:i+6].ljust(6, '0')
                out += tbl[int(chunk, 2)]
            pad = (4 - len(out) % 4) % 4
            return out + "=" * pad
        auth = api_username + ":" + api_password
        auth_header = "Basic " + b64_encode(auth)
        headers["Authorization"] = auth_header
    else:
        fail("Authentication: provide either api_token, api_oauth_token, api_job_token, or api_username with api_password")

    # Resolve project ID
    url = base_url + "/api/v4/projects?search=" + project
    res = ctx.run(
        [
            "curl", "-sS", "--fail",
        ] + (
            ["--user", api_username + ":" + api_password] if api_username and api_password else []
        ) + [
            url,
        ],
        ok_codes=[0]
    )
    if res.rc != 0:
        fail("Failed to lookup project %s: %s" % (project, res.stderr))

    # Simple JSON parser for array of project objects
    def parse_projects(s):
        s = s.strip()
        if not s.startswith("["):
            if s.startswith("{"):
                s = "[" + s + "]"
            else:
                return []
        s = s[1:-1].strip()
        if not s:
            return []
        out = []
        depth = 0
        current = ""
        for c in s:
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
            if depth == 0:
                if current.strip():
                    out.append(current.strip())
                current = ""
            else:
                current += c
        if current.strip():
            out.append(current.strip())
        projects_list = []
        for obj in out:
            obj = obj.strip()
            if not obj.startswith("{") or not obj.endswith("}"):
                continue
            data = {}
            # Split by top-level commas (simple approach assuming no commas inside values)
            parts = obj[1:-1].split(",")
            for p in parts:
                p = p.strip()
                if ":" not in p:
                    continue
                k, v = p.split(":", 1)
                k = k.strip().strip('"')
                v = v.strip().strip('"')
                if k == "id":
                    if v.isdigit():
                        data[k] = int(v)
                    else:
                        data[k] = v
                else:
                    data[k] = v
            if "id" in data and "path" in data:
                projects_list.append({"id": data["id"], "path": data["path"]})
        return projects_list

    projects_list = parse_projects(res.stdout)

    proj_id = None
    for p in projects_list:
        if p["path"] == project or p["path"].split("/")[-1] == project:
            proj_id = p["id"]
            break

    if proj_id == None:
        fail("Project %s not found" % project)

    # Helper: list badges
    def list_badges():
        url = base_url + "/api/v4/projects/" + str(proj_id) + "/badges"
        res = ctx.run(
            [
                "curl", "-sS", "--fail",
            ] + (
                ["--user", api_username + ":" + api_password] if api_username and api_password else []
            ) + [
                url,
            ],
            ok_codes=[0]
        )
        if res.rc != 0:
            fail("Failed to list badges: " + res.stderr)
        return parse_badges(res.stdout)

    # Helper: parse badge array JSON
    def parse_badges(s):
        s = s.strip()
        if not s.startswith("["):
            if s.startswith("{"):
                s = "[" + s + "]"
            else:
                return []
        s = s[1:-1].strip()
        if not s:
            return []
        out = []
        depth = 0
        current = ""
        for c in s:
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
            if depth == 0:
                if current.strip():
                    out.append(current.strip())
                current = ""
            else:
                current += c
        if current.strip():
            out.append(current.strip())
        badges = []
        for obj in out:
            obj = obj.strip()
            if not obj.startswith("{") or not obj.endswith("}"):
                continue
            data = {}
            parts = obj[1:-1].split(",")
            for p in parts:
                p = p.strip()
                if ":" not in p:
                    continue
                k, v = p.split(":", 1)
                k = k.strip().strip('"')
                v = v.strip().strip('"')
                data[k] = v
            badges.append(data)
        return badges

    # Helper: get badge by image_url
    def find_badge_by_image_url():
        badges = list_badges()
        for b in badges:
            if b.get("image_url") == image_url:
                return b
        return None

    # Check if badge already matches
    existing = find_badge_by_image_url()
    if state == "present":
        if existing:
            # Check if link_url already correct
            if existing.get("link_url") == link_url:
                return {"changed": False, "msg": "Badge already exists with correct link_url", "badge": existing}
            # Update required
            if ctx.check_mode:
                return {"changed": True, "msg": "would update badge link_url", "badge": existing}
            # PATCH badge
            url = base_url + "/api/v4/projects/" + str(proj_id) + "/badges/" + str(existing.get("id"))
            res = ctx.run(
                [
                    "curl", "-sS", "--fail", "-X", "PUT",
                ] + (
                    ["--user", api_username + ":" + api_password] if api_username and api_password else []
                ) + [
                    url,
                    "--data", '{"link_url":"%s"}' % link_url,
                ],
                ok_codes=[0]
            )
            if res.rc != 0:
                fail("Failed to update badge: " + res.stderr)
            # Parse updated badge
            updated_badges = parse_badges(res.stdout)
            if updated_badges:
                updated = updated_badges[0]
            else:
                updated = existing  # fallback
            updated["link_url"] = link_url
            return {"changed": True, "msg": "badge updated", "badge": updated}
        # Create new badge
        if ctx.check_mode:
            return {"changed": True, "msg": "would create badge", "badge": {"link_url": link_url, "image_url": image_url}}
        url = base_url + "/api/v4/projects/" + str(proj_id) + "/badges"
        res = ctx.run(
            [
                "curl", "-sS", "--fail", "-X", "POST",
            ] + (
                ["--user", api_username + ":" + api_password] if api_username and api_password else []
            ) + [
                url,
                "--data", '{"link_url":"%s","image_url":"%s"}' % (link_url, image_url),
            ],
            ok_codes=[0]
        )
        if res.rc != 0:
            fail("Failed to create badge: " + res.stderr)
        created_badges = parse_badges(res.stdout)
        if created_badges:
            created = created_badges[0]
        else:
            created = {"link_url": link_url, "image_url": image_url}
        return {"changed": True, "msg": "badge created", "badge": created}
    elif state == "absent":
        if not existing:
            return {"changed": False, "msg": "badge not present"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete badge"}
        url = base_url + "/api/v4/projects/" + str(proj_id) + "/badges/" + str(existing.get("id"))
        res = ctx.run(
            [
                "curl", "-sS", "--fail", "-X", "DELETE",
            ] + (
                ["--user", api_username + ":" + api_password] if api_username and api_password else []
            ) + [
                url,
            ],
            ok_codes=[0]
        )
        if res.rc != 0:
            fail("Failed to delete badge: " + res.stderr)
        return {"changed": True, "msg": "badge deleted"}
