def main(ctx, params):
    if params.get("_discover"):
        data_file = "/var/lib/check-mk-agent/local/jira_workflow"
        if ctx.file_exists(data_file):
            content = ctx.file_read(data_file)
            if not content:
                section = {}
            else:
                section = parse_jira_workflow(content.splitlines())
        else:
            section = {}
        
        out = []
        for item in section:
            out.append({
                "item": item,
                "params": {"workflow_count_upper": (None, None), "workflow_count_lower": (None, None)},
                "metrics": ["jira_count"]
            })
        return {"changed": False, "msg": "discovered %d items" % len(out), "data": {"discovery": out}}

    item = params.get("item", "")
    data_file = "/var/lib/check-mk-agent/local/jira_workflow"
    if not ctx.file_exists(data_file):
        return {"changed": False, "msg": "no data file: " + data_file,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    content = ctx.file_read(data_file)
    if not content:
        return {"changed": False, "msg": "empty data file",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    
    section = parse_jira_workflow(content.splitlines())
    item_data = section.get(item)
    if item_data == None:
        return {"changed": False, "msg": "no such item: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    msg_error = item_data.get("error")
    if msg_error != None:
        return {"changed": False, "msg": "Jira error while searching (see long output for details)",
                "data": {"state": "CRIT", "metrics": {}, "details": "Jira error while searching (see long output for details)\n" + str(msg_error)}}

    total_issues = 0
    for workflow, count in item_data.items():
        if type(count) == "int":
            total_issues = total_issues + count

    warn_upper = params.get("workflow_count_upper", (None, None))
    warn_lower = params.get("workflow_count_lower", (None, None))

    state = "OK"
    if warn_upper != None and len(warn_upper) >= 2:
        crit_upper = warn_upper[1]
        if total_issues >= crit_upper:
            state = "CRIT"
        elif total_issues >= warn_upper[0]:
            state = "WARN"
    
    if warn_lower != None and len(warn_lower) >= 2:
        crit_lower = warn_lower[1]
        if total_issues <= crit_lower[0]:
            state = "CRIT"
        elif total_issues <= warn_lower[0]:
            state = "WARN"

    msg = "Total issues: " + str(total_issues)
    
    return {"changed": False, "msg": msg, "data": {"state": state, "metrics": {"jira_count": total_issues}, "details": ""}}


def parse_jira_workflow(lines):
    parsed = {}
    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        # Guard against malformed JSON without try/except
        projects = json.decode(stripped) if stripped else {}
        if type(projects) != "dict":
            continue
        for project in projects:
            workflows = projects.get(project)
            if workflows == None:
                continue
            if type(workflows) != "dict":
                continue
            for workflow in workflows:
                issue_count = workflows.get(workflow)
                if issue_count == None:
                    continue
                if type(issue_count) == "int":
                    key = project.title() + "/" + workflow.title()
                    item = parsed.get(key)
                    if item == None:
                        item = {}
                        parsed[key] = item
                    item[workflow] = issue_count
    return parsed