STATE_ORDER = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}

def _worst(a, b):
    if STATE_ORDER.get(a, 0) >= STATE_ORDER.get(b, 0):
        return a
    return b

def _apply_levels(value, upper, lower):
    wu = upper[0] if len(upper) > 0 else None
    cu = upper[1] if len(upper) > 1 else None
    wl = lower[0] if len(lower) > 0 else None
    cl = lower[1] if len(lower) > 1 else None
    state = "OK"
    if cu != None and value >= cu:
        state = "CRIT"
    elif wu != None and value >= wu:
        state = "WARN"
    if cl != None and value <= cl:
        state = _worst(state, "CRIT")
    elif wl != None and value <= wl:
        state = _worst(state, "WARN")
    return state

def _is_numeric_str(s):
    s2 = s.strip().replace(".", "").replace("-", "")
    return len(s2) > 0 and s2.isdigit()

def _jira_search(ctx, base_url, user, token, jql, fields, start_at, max_results):
    return ctx.run([
        "curl", "-s", "-G",
        "-u", user + ":" + token,
        "-H", "Accept: application/json",
        "--data-urlencode", "jql=" + jql,
        "--data-urlencode", "startAt=" + str(start_at),
        "--data-urlencode", "maxResults=" + str(max_results),
        "--data-urlencode", "fields=" + fields,
        base_url + "/rest/api/2/search",
    ], mutates=False)

def main(ctx, params):
    jira_url = params.get("jira_url", "")
    user = params.get("jira_user", "")
    token = params.get("jira_token", "")
    services = params.get("services", [])

    if params.get("_discover"):
        discovery = []
        for svc in services:
            name = svc.get("name", "")
            if not name:
                continue
            computation = svc.get("computation", "count")
            if computation == "count":
                metrics = ["jira_count"]
            elif computation == "sum":
                metrics = ["jira_sum"]
            else:
                metrics = ["jira_avg"]
            discovery.append({
                "item": name.title(),
                "params": {},
                "metrics": metrics,
            })
        return {
            "changed": False,
            "msg": "discovered %d services" % len(discovery),
            "data": {"discovery": discovery},
        }

    # Check mode
    item = params.get("item", "")
    svc_config = None
    for svc in services:
        if svc.get("name", "").title() == item:
            svc_config = svc
            break

    if svc_config == None:
        return {
            "changed": False,
            "msg": "service not configured: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if not jira_url or not user or not token:
        return {
            "changed": False,
            "msg": "missing Jira connection params (jira_url, jira_user, jira_token)",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    jql = svc_config.get("jql", "")
    computation = svc_config.get("computation", "count")
    field_name = svc_config.get("field", "")
    base_url = jira_url.rstrip("/")

    if not jql:
        return {
            "changed": False,
            "msg": "no JQL query configured for item: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    if computation == "count":
        res = _jira_search(ctx, base_url, user, token, jql, "id", 0, 0)
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "Jira API request failed",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stderr},
            }
        if not res.stdout:
            return {
                "changed": False,
                "msg": "empty response from Jira",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
            }
        data = json.decode(res.stdout)
        err_msgs = data.get("errorMessages")
        if err_msgs != None and len(err_msgs) > 0:
            detail = "Jira error while searching\n" + "\n".join(err_msgs)
            return {
                "changed": False,
                "msg": "Jira error while searching (see details)",
                "data": {"state": "CRIT", "metrics": {}, "details": detail},
            }
        count = int(data.get("total", 0))
        upper = params.get("custom_svc_count_upper", [None, None])
        lower = params.get("custom_svc_count_lower", [None, None])
        state = _apply_levels(count, upper, lower)
        return {
            "changed": False,
            "msg": "Total number of issues: %d" % count,
            "data": {"state": state, "metrics": {"jira_count": count}, "details": ""},
        }

    # sum or avg: must aggregate a numeric field across all matching issues
    if not field_name:
        return {
            "changed": False,
            "msg": "field param required for computation: " + computation,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    res = _jira_search(ctx, base_url, user, token, jql, field_name, 0, 100)
    if res.rc != 0 or not res.stdout:
        return {
            "changed": False,
            "msg": "Jira API request failed",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": res.stderr},
        }
    data = json.decode(res.stdout)
    err_msgs = data.get("errorMessages")
    if err_msgs != None and len(err_msgs) > 0:
        detail = "Jira error while searching\n" + "\n".join(err_msgs)
        return {
            "changed": False,
            "msg": "Jira error while searching (see details)",
            "data": {"state": "CRIT", "metrics": {}, "details": detail},
        }

    total = data.get("total", 0)
    all_issues = [iss for iss in data.get("issues", [])]

    # Paginate up to 1000 issues (10 pages x 100)
    for _ in range(9):
        fetched = len(all_issues)
        if fetched >= total or fetched >= 1000:
            break
        page_res = _jira_search(ctx, base_url, user, token, jql, field_name, fetched, 100)
        if page_res.rc != 0 or not page_res.stdout:
            break
        page_data = json.decode(page_res.stdout)
        page_issues = page_data.get("issues", [])
        if not page_issues:
            break
        for iss in page_issues:
            all_issues.append(iss)

    # Aggregate the numeric field
    total_sum = 0.0
    total_count = 0
    for issue in all_issues:
        fields_dict = issue.get("fields", {})
        raw_val = fields_dict.get(field_name)
        if raw_val == None:
            continue
        rv_type = type(raw_val)
        if rv_type == "int" or rv_type == "float":
            total_sum = total_sum + float(raw_val)
            total_count = total_count + 1
        elif rv_type == "string" and _is_numeric_str(raw_val):
            total_sum = total_sum + float(raw_val.strip())
            total_count = total_count + 1

    if computation == "sum":
        upper = params.get("custom_svc_sum_upper", [None, None])
        lower = params.get("custom_svc_sum_lower", [None, None])
        state = _apply_levels(total_sum, upper, lower)
        return {
            "changed": False,
            "msg": "Result of summed up values: %d" % int(total_sum),
            "data": {"state": state, "metrics": {"jira_sum": total_sum}, "details": ""},
        }

    # avg
    avg_val = total_sum / total_count if total_count > 0 else 0.0
    upper = params.get("custom_svc_avg_upper", [None, None])
    lower = params.get("custom_svc_avg_lower", [None, None])
    state = _apply_levels(avg_val, upper, lower)
    details = "(Summed up values: %s / Total search results: %d)" % (str(total_sum), total_count)
    return {
        "changed": False,
        "msg": "Average value: %f %s" % (avg_val, details),
        "data": {
            "state": state,
            "metrics": {
                "jira_avg": avg_val,
                "jira_avg_sum": total_sum,
                "jira_avg_total": float(total_count),
            },
            "details": "",
        },
    }