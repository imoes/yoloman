def main(ctx, params):
    if params.get("_discover"):
        res = ctx.run(["lsrsrc", "-A", "IBM.ResourceGroup"], mutates=False)
        section = {}
        for line in res.stdout.splitlines():
            # Skip empty lines
            if not line.strip():
                continue
            # Example: "Resource Group "caa" { Subsystem "clcomd" { State = "Active" } }"
            # Look for Resource Group lines to identify sections
            if line.find("Resource Group") != -1:
                # Extract group name between quotes
                start = line.find('"')
                if start != -1:
                    end = line.find('"', start + 1)
                    if end != -1:
                        group_name = line[start + 1:end]
                        section[group_name] = []
            # Look for Subsystem lines
            elif line.find("Subsystem") != -1 and line.find("State") != -1:
                # Extract subsystem name
                start = line.find('"')
                if start != -1:
                    end = line.find('"', start + 1)
                    if end != -1:
                        subsys_name = line[start + 1:end]
                        # Extract state (Active/Inactive etc.)
                        state_part = line.rsplit("State", 1)[-1].strip()
                        if state_part.startswith("="):
                            state_part = state_part[1:].strip()
                        # Extract status word
                        status = "active" if state_part.lower().find("active") != -1 else "inactive"
                        if group_name in section:
                            section[group_name].append((subsys_name, status))
        # Also try the more direct approach via lsrsrc Resource
        if not section:
            res = ctx.run(["lsrsrc", "Resource"], mutates=False)
            for line in res.stdout.splitlines():
                if line.find("Resource") != -1 and line.find("ResourceGroup") != -1:
                    start = line.find('"')
                    if start != -1:
                        end = line.find('"', start + 1)
                        if end != -1:
                            group_name = line[start + 1:end]
                            if group_name not in section:
                                section[group_name] = []
                elif line.find("Resource") != -1 and line.find("SubSystem") != -1:
                    start = line.find('"')
                    if start != -1:
                        end = line.find('"', start + 1)
                        if end != -1:
                            subsys_name = line[start + 1:end]
                            # Extract state
                            state_part = line.rsplit("State", 1)[-1].strip()
                            if state_part.startswith("="):
                                state_part = state_part[1:].strip()
                            status = "active" if state_part.lower().find("active") != -1 else "inactive"
                            if group_name in section:
                                section[group_name].append((subsys_name, status))
        discovery = []
        for item in section:
            # Collect metrics from all subsystems in this group
            metrics = []
            for subsys_name, status in section[item]:
                metrics.append("status_" + subsys_name)
            discovery.append({
                "item": item,
                "params": {},
                "metrics": metrics
            })
        return {
            "changed": False,
            "msg": "discovered %d HACMP service groups" % len(discovery),
            "data": {"discovery": discovery}
        }

    item = params.get("item", "")
    res = ctx.run(["lsrsrc", "-A", "IBM.ResourceGroup"], mutates=False)
    section = {}
    for line in res.stdout.splitlines():
        if not line.strip():
            continue
        if line.find("Resource Group") != -1:
            start = line.find('"')
            if start != -1:
                end = line.find('"', start + 1)
                if end != -1:
                    group_name = line[start + 1:end]
                    section[group_name] = []
        elif line.find("Subsystem") != -1 and line.find("State") != -1:
            start = line.find('"')
            if start != -1:
                end = line.find('"', start + 1)
                if end != -1:
                    subsys_name = line[start + 1:end]
                    state_part = line.rsplit("State", 1)[-1].strip()
                    if state_part.startswith("="):
                        state_part = state_part[1:].strip()
                    status = "active" if state_part.lower().find("active") != -1 else "inactive"
                    if group_name in section:
                        section[group_name].append((subsys_name, status))

    # Fallback discovery if the first method didn't find anything
    if not section:
        res = ctx.run(["lsrsrc", "Resource"], mutates=False)
        for line in res.stdout.splitlines():
            if line.find("Resource") != -1 and line.find("ResourceGroup") != -1:
                start = line.find('"')
                if start != -1:
                    end = line.find('"', start + 1)
                    if end != -1:
                        group_name = line[start + 1:end]
                        if group_name not in section:
                            section[group_name] = []
            elif line.find("Resource") != -1 and line.find("SubSystem") != -1:
                start = line.find('"')
                if start != -1:
                    end = line.find('"', start + 1)
                    if end != -1:
                        subsys_name = line[start + 1:end]
                        state_part = line.rsplit("State", 1)[-1].strip()
                        if state_part.startswith("="):
                            state_part = state_part[1:].strip()
                        status = "active" if state_part.lower().find("active") != -1 else "inactive"
                        if group_name in section:
                            section[group_name].append((subsys_name, status))

    # Get data for this item (group)
    if not section.get(item):
        return {
            "changed": False,
            "msg": "no data for service group: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    state = "OK"
    details = []
    metrics = {}
    for subsytem_name, status in section[item]:
        status_code = 0 if status == "active" else 2
        if status_code == 2:
            if state == "OK":
                state = "CRIT"
        elif status_code == 1:
            if state == "OK":
                state = "WARN"
        details.append("Subsystem: %s, Status: %s" % (subsytem_name, status))
        metrics["status_" + subsytem_name] = 0 if status == "active" else 1

    return {
        "changed": False,
        "msg": "; ".join(details),
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }
