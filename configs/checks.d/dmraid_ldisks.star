def main(ctx, params):
    if params.get("_discover"):
        # Discover logical disks by running the dmraid command
        res = ctx.run(["dmraid", "-r", "-n"], mutates=False)
        disks = []
        # Parse dmraid output: each line is "name   : <disk_name>"
        for line in res.stdout.splitlines():
            parts = line.split(":")
            if len(parts) >= 2:
                disk_name = parts[1].strip()
                if disk_name:
                    disks.append({"item": disk_name, "params": {}, "metrics": []})
        return {
            "changed": False,
            "msg": "discovered %d logical disks" % len(disks),
            "data": {"discovery": disks}
        }

    # Check mode: examine one logical disk item
    item = params.get("item", "")
    res = ctx.run(["dmraid", "-r", "-n"], mutates=False)
    lines = res.stdout.splitlines()
    
    # Search for the requested logical disk
    found = False
    status_value = ""
    for line in lines:
        parts = line.split(":")
        if len(parts) >= 2:
            key = parts[0].strip()
            value = parts[1].strip()
            if key == "name" and value == item:
                found = True
            elif found and key == "status":
                status_value = value
                break
    
    if not found:
        return {
            "changed": False,
            "msg": "incomplete data from agent",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }
    
    if status_value == "ok":
        state = "OK"
        summary = "state is ok"
    else:
        state = "CRIT"
        summary = status_value if status_value else "unknown"
    
    return {
        "changed": False,
        "msg": summary,
        "data": {"state": state, "metrics": {}, "details": ""}
    }