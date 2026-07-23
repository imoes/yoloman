def main(ctx, params):
    # Discover mode: fetch Azure status and list regions as items
    if params.get("_discover"):
        res = ctx.run(["curl", "-sS", "https://azure.status.microsoft/en-us/status"], mutates=False)
        if res.rc != 0:
            return {"changed": False, "msg": "curl failed: " + res.stderr,
                    "data": {"discovery": []}}
        if not res.stdout:
            return {"changed": False, "msg": "empty response from Azure status",
                    "data": {"discovery": []}}
        data = json.decode(res.stdout)
        # Validate expected JSON structure
        if type(data) != "dict":
            return {"changed": False, "msg": "JSON root is not object",
                    "data": {"discovery": []}}

        # Extract regions list
        regions = data.get("regions", [])
        if type(regions) != "list":
            return {"changed": False, "msg": "invalid regions field in JSON",
                    "data": {"discovery": []}}

        discovery_list = []
        for r in regions:
            if type(r) == "string" and r:
                discovery_list.append({"item": r, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d regions" % len(discovery_list),
                "data": {"discovery": discovery_list}}

    # Check mode: examine one region's issues
    item = params.get("item", "")
    res = ctx.run(["curl", "-sS", "https://azure.status.microsoft/en-us/status"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "curl failed: " + res.stderr,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    if not res.stdout:
        return {"changed": False, "msg": "empty response from Azure status",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = json.decode(res.stdout)
    # Validate expected JSON structure
    if type(data) != "dict":
        return {"changed": False, "msg": "JSON root is not object",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Parse regions into a map: region -> list of issues
    regions_dict = {}
    region_list = data.get("regions", [])
    if type(region_list) != "list":
        region_list = []

    # Initialize empty lists for known regions
    for r in region_list:
        if type(r) == "string":
            regions_dict[r] = []

    # Collect issues by region
    issues_list = data.get("issues", [])
    if type(issues_list) != "list":
        issues_list = []

    for issue in issues_list:
        if type(issue) == "dict":
            region = issue.get("region", "")
            if type(region) == "string":
                if region not in regions_dict:
                    regions_dict[region] = []
                regions_dict[region].append({
                    "title": issue.get("title", ""),
                    "description": issue.get("description", "")
                })

    # Get issues for this item (region)
    region_issues = regions_dict.get(item)
    if region_issues == None:
        return {"changed": False, "msg": "region not found: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Build result
    if not region_issues:
        link = data.get("link", "")
        if link == None:
            link = "https://azure.status.microsoft/en-us/status"
        return {"changed": False, "msg": "No known issues. Details: " + link,
                "data": {"state": "OK", "metrics": {}, "details": ""}}

    # There are issues
    issue_count = len(region_issues)
    link = data.get("link", "")
    if link == None:
        link = "https://azure.status.microsoft/en-us/status"

    issue_word = "issue" if issue_count == 1 else "issues"
    msg = "%d %s: %s" % (issue_count, issue_word, link)
    summary_lines = [msg]
    for iss in region_issues:
        title = iss.get("title", "")
        if title == None:
            title = ""
        summary_lines.append(title)

    return {"changed": False, "msg": "; ".join(summary_lines),
            "data": {"state": "WARN", "metrics": {}, "details": ""}}