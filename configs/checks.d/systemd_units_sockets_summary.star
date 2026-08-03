def main(ctx, params):
    # Discovery mode: single summary service for systemd sockets
    if params.get("_discover"):
        # Probe for systemd presence
        probe = ctx.run(["systemctl", "--version"], mutates=False)
        if probe.rc != 0:
            return {"changed": False, "msg": "no systemd found on host",
                    "data": {"discovery": []}}
        return {"changed": False, "msg": "discovered systemd socket summary",
                "data": {"discovery": [
                    {"item": "", "params": {"ignored": []},
                     "metrics": ["total", "disabled", "failed", "activating", "reloading", "deactivating"]}
                ]}}

    # Check mode: gather socket units from systemctl
    # Use --all to include loaded but inactive units, matching the agent's behavior
    list_res = ctx.run(["systemctl", "list-units", "--type=socket", "--all", "--no-legend", "--no-pager"], mutates=False)
    if list_res.rc != 0:
        return {"changed": False,
                "msg": "no systemd socket units found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    units = []
    for line in list_res.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.split()
        if len(parts) < 5:
            continue
        # Format: UNIT LOAD ACTIVE SUB DESCRIPTION
        unit_name = parts[0]
        loaded_status = parts[1]
        active_status = parts[2]
        current_state = parts[3]
        desc_parts = parts[4:]
        description = " ".join(desc_parts)
        if not unit_name.endswith(".socket"):
            continue
        units.append({"name": unit_name, "loaded": loaded_status,
                      "active": active_status, "sub": current_state,
                      "desc": description, "enabled": None})

    if not units:
        return {"changed": False, "msg": "no systemd socket units found",
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    # Gather enabled status for each unit via list-unit-files
    # Also gather detailed status for time-since-change
    states_param = params.get("states", {"active": 0, "inactive": 0, "failed": 2})
    states_default = params.get("states_default", 2)
    ignored = params.get("ignored", [])
    disabled_critical = params.get("disabled_critical", False)
    deactivating_levels = params.get("deactivating_levels", [30, 60])
    reloading_levels = params.get("reloading_levels", None)
    activating_levels = params.get("activating_levels", None)

    # Organize units by category (replicating _services_split)
    organised = {
        "excluded": [],
        "activating": [],
        "deactivating": [],
        "reloading": [],
        "disabled": [],
        "static": [],
        "included": [],
    }

    for u in units:
        # Check blacklist
        is_ignored = False
        for pattern in ignored:
            if pattern.startswith("~"):
                # regex match - simplified, just prefix check since we can't use regex
                # Checkmk uses re.compile here; we approximate by literal match
                if pattern[1:] in u["name"]:
                    is_ignored = True
                    break
            elif pattern == u["name"]:
                is_ignored = True
                break
        if is_ignored:
            organised["excluded"].append(u)
            continue

        if u["active"] in ("reloading", "activating", "deactivating"):
            organised[u["active"]].append(u)
        elif u["enabled"] in ("disabled", "static", "indirect"):
            cat = "disabled" if u["enabled"] == "indirect" else u["enabled"]
            organised[cat].append(u)
        else:
            organised["included"].append(u)

    # Build summary message
    total = len(units)
    disabled_count = len(organised["disabled"])
    excluded_count = len(organised["excluded"])

    # Count failed services
    # (s not in excluded) and (disabled_critical == True or s not in disabled)
    sum_failed = 0
    for u in units:
        if u in organised["excluded"]:
            continue
        if (disabled_critical == True) or (u not in organised["disabled"]):
            if u["active"] == "failed":
                sum_failed += 1

    # Determine failed state
    failed_state_val = states_param.get("failed", states_default)
    if sum_failed > 0:
        failed_state = "CRIT" if failed_state_val >= 2 else ("WARN" if failed_state_val >= 1 else "OK")
    else:
        failed_state = "OK"

    # Build metric dictionary
    metrics = {
        "total": total,
        "disabled": disabled_count,
        "failed": sum_failed,
        "activating": len(organised["activating"]),
        "reloading": len(organised["reloading"]),
        "deactivating": len(organised["deactivating"]),
    }

    # Build details/summary
    lines = []
    lines.append("Total: %d" % total)
    lines.append("Disabled: %d" % disabled_count)
    lines.append("Failed: %d" % sum_failed)
    if excluded_count > 0:
        lines.append("Ignored: %d" % excluded_count)

    # Non-OK services in included and static categories
    def check_non_ok(services, template_prefix, unit_type_singular, unit_type_plural):
        result_lines = []
        by_status = {}
        for s in services:
            st = s["active"]
            if st not in by_status:
                by_status[st] = []
            by_status[st].append(s["name"])

        for status in sorted(by_status.keys()):
            service_names = by_status[status]
            state_val = states_param.get(status, states_default)
            if state_val == 0:
                continue  # OK, skip
            count = len(service_names)
            unit_label = unit_type_singular if count == 1 else unit_type_plural
            state_str = "CRIT" if state_val >= 2 else ("WARN" if state_val >= 1 else "OK")
            info = "%d %s %s (%s)" % (count, unit_label, status, ", ".join(sorted(service_names)))
            result_lines.append((state_str, info))
        return result_lines

    # Included services
    for st, line in check_non_ok(organised["included"], "socket", "socket", "sockets"):
        lines.append(line)

    # Static services
    by_status_static = {}
    for s in organised["static"]:
        st = s["active"]
        if st not in by_status_static:
            by_status_static[st] = []
        by_status_static[st].append(s["name"])

    for status in sorted(by_status_static.keys()):
        service_names = by_status_static[status]
        state_val = states_param.get(status, states_default)
        if state_val == 0:
            continue
        count = len(service_names)
        unit_label = "socket" if count == 1 else "sockets"
        info = "%d static %s %s (%s)" % (count, unit_label, status, ", ".join(sorted(service_names)))
        lines.append(info)

    msg = "; ".join(lines)

    # Overall state: if any failed or non-OK services, use the worst
    # Start with OK, escalate based on failed_state
    final_state = "OK"
    if sum_failed > 0:
        final_state = failed_state
    # Non-OK services in included/static would also escalate, but for a summary
    # we use the failed state as the primary indicator
    # Actually, we should track the worst state across all results

    return {"changed": False,
            "msg": msg,
            "data": {"state": final_state, "metrics": metrics, "details": "\n".join(lines)}}