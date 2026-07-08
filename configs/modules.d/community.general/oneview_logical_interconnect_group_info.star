def main(ctx, params):
    name = params.get("name")
    ligs = None

    # Build optional query parameters for get_all
    query_kwargs = {}
    if params.get("params"):
        p = params["params"]
        if p.get("start") != None:
            query_kwargs["start"] = int(p["start"])
        if p.get("count") != None:
            query_kwargs["count"] = int(p["count"])
        if p.get("filter") != None:
            query_kwargs["filter"] = str(p["filter"])
        if p.get("sort") != None:
            query_kwargs["sort"] = str(p["sort"])

    # Probe current state: in check_mode we run the same probe, we don't mutate
    if name != None:
        # Simulate get_by('name', name) — call the OneView API via curl
        # Note: This assumes a pre-authenticated session or credentials are provided
        # and accessible through environment variables or config (handled by OneView client logic).
        # Since Starlark cannot call Python SDK, we delegate to curl-based REST call.

        # Construct base URL (hostname/api_version)
        hostname = params.get("hostname")
        if hostname == None:
            fail("hostname is required")
        api_version = params.get("api_version")
        if api_version == None:
            fail("api_version is required")
        url = "https://%s/rest/logical-interconnect-groups?filter=name='%s'" % (hostname, name)
        cmd = ["curl", "-s", "-k", "-H", "Accept: application/json", url]
        if params.get("username"):
            cmd += ["-u", str(params["username"]) + ":" + str(params["password"])]
        res = ctx.run(cmd, mutates=False)
        if res.rc != 0:
            fail("failed to query logical interconnect group by name: " + res.stderr)
        # Parse JSON manually: find 'members' array
        output = res.stdout
        # Simple extraction: look for '"members":\[...]'
        start_idx = output.find('"members":[')
        if start_idx == -1:
            ligs = []
        else:
            # Find matching closing bracket (naive counting)
            depth = 0
            i = start_idx + len('"members":[')
            end_idx = i
            while i < len(output):
                c = output[i]
                if c == '[':
                    depth += 1
                elif c == ']':
                    depth -= 1
                    if depth == 0:
                        end_idx = i + 1
                        break
                i += 1
            members_str = output[start_idx + len('"members":['):end_idx]
            # Parse list of objects: split by },{ and reconstruct each
            if members_str == "":
                ligs = []
            else:
                # Split by },{ safely (naive)
                items = members_str.split("},{")
                ligs = []
                for item in items:
                    item = item.strip()
                    if item.startswith("{") and item.endswith("}"):
                        item = item[1:-1]
                        # Extract 'name' and 'uri' minimally for display
                        name_val = ""
                        uri_val = ""
                        # Very naive extraction (real use would need robust JSON parsing, but Starlark has no json module)
                        # Instead, return raw members list as list of dicts if possible, else fallback
                        # For simplicity, return list of raw strings for now — user may use debug/filter
                        ligs.append(item)
    else:
        # get_all
        hostname = params.get("hostname")
        if hostname == None:
            fail("hostname is required")
        api_version = params.get("api_version")
        if api_version == None:
            fail("api_version is required")
        url = "https://%s/rest/logical-interconnect-groups" % hostname
        cmd = ["curl", "-s", "-k", "-H", "Accept: application/json", url]
        if params.get("username"):
            cmd += ["-u", str(params["username"]) + ":" + str(params["password"])]
        if len(query_kwargs) > 0:
            # Build query string
            q = []
            if query_kwargs.get("start") != None:
                q += ["start=" + str(query_kwargs["start"])]
            if query_kwargs.get("count") != None:
                q += ["count=" + str(query_kwargs["count"])]
            if query_kwargs.get("filter") != None:
                q += ["filter=" + str(query_kwargs["filter"])]
            if query_kwargs.get("sort") != None:
                q += ["sort=" + str(query_kwargs["sort"])]
            if len(q) > 0:
                url += "?" + "&".join(q)
        res = ctx.run(cmd, mutates=False)
        if res.rc != 0:
            fail("failed to query logical interconnect groups: " + res.stderr)
        output = res.stdout
        start_idx = output.find('"members":[')
        if start_idx == -1:
            ligs = []
        else:
            depth = 0
            i = start_idx + len('"members":[')
            end_idx = i
            while i < len(output):
                c = output[i]
                if c == '[':
                    depth += 1
                elif c == ']':
                    depth -= 1
                    if depth == 0:
                        end_idx = i + 1
                        break
                i += 1
            members_str = output[start_idx + len('"members":['):end_idx]
            if members_str == "":
                ligs = []
            else:
                items = members_str.split("},{")
                ligs = []
                for item in items:
                    item = item.strip()
                    if item.startswith("{") and item.endswith("}"):
                        item = item[1:-1]
                        ligs.append(item)

    # Ensure ligs is always a list
    if ligs == None:
        ligs = []

    return {"changed": False, "logical_interconnect_groups": ligs}
