MONITORED_TASKS = ["Real-time protection", "System:EventManager"]

def _parse_tasks(output):
    tasks = {}
    current_name = None
    for line in output.splitlines():
        stripped = line.strip()
        if stripped.startswith("Name:"):
            current_name = stripped[5:].strip()
            tasks[current_name] = {}
        elif current_name != None:
            colon_pos = stripped.find(":")
            if colon_pos > 0:
                key = stripped[:colon_pos].strip()
                val = stripped[colon_pos + 1:].strip()
                tasks[current_name][key] = val
    return tasks

def main(ctx, params):
    res = ctx.run(["kesl-control", "--get-task-list"], mutates=False)
    tasks = _parse_tasks(res.stdout)

    if params.get("_discover"):
        discovered = []
        for name in tasks:
            if name == "Real-time protection" or name == "System:EventManager":
                discovered.append({
                    "item": name,
                    "params": {},
                    "metrics": [],
                })
        return {
            "changed": False,
            "msg": "discovered %d tasks" % len(discovered),
            "data": {"discovery": discovered},
        }

    item = params.get("item", "")
    if item not in tasks:
        return {
            "changed": False,
            "msg": "Task not found in agent output",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    task_state = tasks[item].get("State", "")
    state = "OK" if task_state == "Started" else "CRIT"
    return {
        "changed": False,
        "msg": "Current state is " + task_state,
        "data": {"state": state, "metrics": {}, "details": ""},
    }