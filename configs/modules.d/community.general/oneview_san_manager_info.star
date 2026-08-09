def main(ctx, params):
    # Extract optional parameters
    provider_display_name = params.get("provider_display_name")
    query_params = params.get("params", {})

    # Build query args: only support start, count, query, sort keys
    allowed_keys = ["start", "count", "query", "sort"]
    filtered_params = {}
    for k in allowed_keys:
        if k in query_params:
            filtered_params[k] = query_params[k]

    # Determine which endpoint to call
    if provider_display_name != None:
        # Get single by provider_display_name
        endpoint = "/rest/san-managers?filter=" + "providerDisplayName=" + provider_display_name
        res = ctx.run(["oneview_cli", "get", endpoint], mutates=False)
        if res.rc != 0:
            fail("failed to fetch SAN manager by provider_display_name " + provider_display_name + ": " + res.stderr)
        # Parse JSON manually: naive extraction of first element if list
        data = res.stdout
        if data == None or data.strip() == "":
            san_managers = []
        else:
            # Very simple extraction: find [ and ] and extract content if it's a list
            stripped = data.strip()
            if stripped.startswith("["):
                # Extract items between [ and ]
                inner = stripped[1:-1].strip()
                if inner == "":
                    san_managers = []
                else:
                    # Assume single object list if content looks like an object
                    if inner.startswith("{"):
                        san_managers = [inner]
                    else:
                        # Fallback: treat as list with one item
                        san_managers = [inner]
            elif stripped.startswith("{"):
                san_managers = [stripped]
            else:
                san_managers = []
    else:
        # Get all with pagination/sorting/filtering
        endpoint = "/rest/san-managers"
        # Build query string
        qparts = []
        for k, v in filtered_params.items():
            qparts.append(k + "=" + str(v))
        if qparts:
            endpoint = endpoint + "?" + "&".join(qparts)
        res = ctx.run(["oneview_cli", "get", endpoint], mutates=False)
        if res.rc != 0:
            fail("failed to fetch SAN managers: " + res.stderr)
        data = res.stdout
        if data == None or data.strip() == "":
            san_managers = []
        else:
            stripped = data.strip()
            if stripped.startswith("["):
                inner = stripped[1:-1].strip()
                if inner == "":
                    san_managers = []
                else:
                    # Naively split by },{ if multiple objects
                    if inner.find("},{") != -1:
                        items = inner.split("},{")
                        san_managers = ["{" + i + "}" if not i.startswith("{") else i for i in items]
                    else:
                        san_managers = [inner]
            elif stripped.startswith("{"):
                san_managers = [stripped]
            else:
                san_managers = []

    # Return result
    return {"changed": False, "msg": "fetched SAN managers", "data": {"san_managers": san_managers}}
