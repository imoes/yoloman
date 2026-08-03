def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["curl", "-fsSL", "https://status.azure.com/en-us/status", "-H", "Accept: application/json"], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "azure status not available", "data": {"discovery": []}}
        data = json.decode(res.stdout)
        regions = data.get("regions", [])
        discovery = []
        for r in regions:
            discovery.append({"item": r, "params": {}, "metrics": []})
        return {"changed": False, "msg": "discovered %d regions" % len(discovery), "data": {"discovery": discovery}}

    item = params.get("item", "")
    res = ctx.run(["curl", "-fsSL", "https://status.azure.com/en-us/status", "-H", "Accept: application/json"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "azure status not available", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    data = json.decode(res.stdout)
    all_regions = data.get("regions", [])
    if item not in all_regions:
        return {"changed": False, "msg": "region %s not found" % item, "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    link = data.get("link", "https://azure.status.microsoft/en-us/status")
    issues = data.get("issues", [])
    region_issues = [i for i in issues if i.get("region") == item]
    if not region_issues:
        return {"changed": False, "msg": "No known issues. Details: " + link, "data": {"state": "OK", "metrics": {}, "details": ""}}
    issue_word = "issue" if len(region_issues) == 1 else "issues"
    details = ""
    for issue in region_issues:
        details += issue.get("title", "") + ": " + issue.get("description", "") + "\n"
    return {"changed": False, "msg": "%d %s: %s" % (len(region_issues), issue_word, link), "data": {"state": "WARN", "metrics": {}, "details": details.strip()}}