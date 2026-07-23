def main(ctx, params):
    # Always return a single service item (summary check)
    # Discovery mode: yield one entry with item "" (single-service check)
    if params.get("_discover"):
        return {
            "changed": False,
            "msg": "discovered 1 service summary",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {
                            "disabled_critical": False,
                            "states": {
                                "active": 0,
                                "inactive": 0,
                                "failed": 2,
                            },
                            "states_default": 2,
                            "activating_levels": None,
                            "deactivating_levels": [30, 60],
                            "reloading_levels": None,
                            "ignored": [],
                        },
                        "metrics": [],
                    }
                ]
            },
        }

    # Check mode: gather systemd unit data via systemctl
    res = ctx.run(
        ["sh", "-c", "systemctl list-units --type=service,socket --no-legend --no-pager 2>/dev/null"],
        mutates=False
    )
    if res.rc != 0:
        return {
            "changed": False,
            "msg": "Unable to list systemd units",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Gather status details for services
    res_status = ctx.run(
        ["sh", "-c", "systemctl status --all --no-pager 2>/dev/null | grep -E '^\\s*Active:|^\\s*CPU:|^\\s*Memory:|^\\s*Tasks:'"],
        mutates=False
    )
    # We'll parse only list-units output; status details are omitted due to complexity and size

    # Parse list-units
    lines = res.stdout.splitlines()
    services = []
    sockets = []
    for line in lines:
        parts = line.strip().split(None, 4)
        if len(parts) < 5:
            continue
        name = parts[0].rstrip(".service").rstrip(".socket")
        loaded = parts[1]
        active = parts[2]
        sub = parts[3]
        description = parts[4]

        # Only process service/socket units (filter out others like .target, .mount etc.)
        if ".service" in line:
            services.append({
                "name": name,
                "loaded_status": loaded,
                "active_status": active,
                "current_state": sub,
                "description": description,
                "enabled_status": None,
            })
        elif ".socket" in line:
            sockets.append({
                "name": name,
                "loaded_status": loaded,
                "active_status": active,
                "current_state": sub,
                "description": description,
                "enabled_status": None,
            })

    # Apply summary check logic
    units = services  # services_summary checks only services
    params_default = params.get("disabled_critical", False)
    blacklist = params.get("ignored", [])
    if type(blacklist) == "NoneType":
        blacklist = []

    # Filter out excluded (blacklisted) services
    excluded = []
    remaining = []
    for svc in units:
        is_excluded = False
        for pattern in blacklist:
            if type(pattern) == "string":
                if svc["name"] == pattern:
                    is_excluded = True
                    break
                # Note: Checkmk supports regex patterns starting with "~", but we skip regex for simplicity
                # as Starlark has no re support
        if is_excluded:
            excluded.append(svc)
        else:
            remaining.append(svc)

    total = len(units)
    disabled_count = 0
    failed_count = 0
    other_non_ok = []

    # Organize by status
    for svc in remaining:
        if svc["enabled_status"] == "disabled" or svc["enabled_status"] == "indirect":
            disabled_count += 1
        if svc["active_status"] == "failed":
            failed_count += 1
        elif svc["active_status"] not in ("active", "inactive"):
            other_non_ok.append(svc)

    # Determine state
    state = "OK"
    msg_parts = []

    # Total count
    msg_parts.append("Total: %d" % total)

    # Disabled count
    msg_parts.append("Disabled: %d" % disabled_count)

    # Failed count
    if failed_count > 0:
        state = "CRIT"
        msg_parts.append("Failed: %d" % failed_count)

    # Other non-OK services (activating, reloading, etc.)
    if other_non_ok:
        for svc in other_non_ok:
            if svc["active_status"] in ("activating", "deactivating", "reloading"):
                # Only report if levels exceeded — but levels not implemented for this simplified check
                # So always report non-OK
                state = "WARN" if state != "CRIT" else state

    # Build message
    msg = "; ".join(msg_parts)

    return {
        "changed": False,
        "msg": msg,
        "data": {
            "state": state,
            "metrics": {},
            "details": "",
        },
    }