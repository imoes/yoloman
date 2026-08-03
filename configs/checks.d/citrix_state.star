def main(ctx, params):
    # Citrix Instance State check — read-only monitoring of Citrix Hypervisor VM states
    # Data source: `xe` CLI (citrix-state / citrix_state agent plugin equivalent)

    DEFAULT_PARAMS = {
        "registrationstate": {
            "Unregistered": 2,
            "Initializing": 1,
            "Registered": 0,
            "AgentError": 2,
        },
        "vmtoolsstate": {
            "NotPresent": 2,
            "Unknown": 3,
            "NotStarted": 1,
            "Running": 0,
        },
    }

    CONSTANTS_MAP = {
        "maintenancemode": {
            "False": 0,
            "True": 1,
        },
        "powerstate": {
            "Unmanaged": 1,
            "Unknown": 1,
            "Unavailable": 2,
            "Off": 2,
            "On": 0,
            "Suspended": 2,
            "TurningOn": 1,
            "TurningOff": 1,
        },
        "vmtoolsstate": {
            "NotPresent": 2,
            "Unknown": 3,
            "NotStarted": 1,
            "Running": 0,
        },
        "faultstate": {
            "None": 0,
            "FailedToStart": 2,
            "StuckOnBoot": 2,
            "Unregistered": 2,
            "MaxCapacity": 1,
        },
    }

    # --- probe for the real thing: the `xe` binary must be present ---
    probe = ctx.run(["xe", "host-list", "--minimal"], mutates=False)
    if probe.rc == 127:
        return {
            "changed": False,
            "msg": "xe binary not found on this host",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # --- DISCOVERY MODE ---
    if params.get("_discover"):
        # The original check has three plugins; this module implements the
        # main "citrix_state" instance-level check (Service per VM instance).
        # We discover one service if any VM state data is available.
        res = ctx.run(
            ["xe", "vm-list", "is-control-domain=false", "--minimal"],
            mutates=False,
        )
        if res.rc != 0:
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []},
            }

        uuids = [u for u in res.stdout.strip().split(";") if u]
        if len(uuids) == 0:
            return {
                "changed": False,
                "msg": "discovered 0 items",
                "data": {"discovery": []},
            }

        discovery = []
        for uuid in uuids:
            discovery.append({
                "item": uuid,
                "params": dict(DEFAULT_PARAMS),
                "metrics": ["powerstate", "registrationstate", "vmtoolsstate",
                            "faultstate", "maintenancemode"],
            })
        return {
            "changed": False,
            "msg": "discovered %d items" % len(discovery),
            "data": {"discovery": discovery},
        }

    # --- CHECK MODE ---
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no Citrix VM instance specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Gather the instance state fields via `xe vm-param-get`
    # These correspond to the lines the agent plugin would produce:
    #   PowerState, RegistrationState, VMToolsState, FaultState, MaintenanceMode
    state_types = [
        "PowerState",
        "RegistrationState",
        "VMToolsState",
        "FaultState",
        "MaintenanceMode",
    ]

    section_instance = {}
    for st in state_types:
        res = ctx.run(
            ["xe", "vm-param-get", "uuid=%s" % item, "param-name=%s" % st, "-minimal"],
            mutates=False,
        )
        if res.rc == 0 and res.stdout.strip() != "":
            section_instance[st] = res.stdout.strip()
        else:
            section_instance[st] = ""

    if len(section_instance) == 0:
        return {
            "changed": False,
            "msg": "no state data for VM %s" % item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""},
        }

    # Build the monitoring map from params or the constants fallback
    merged_map = dict(DEFAULT_PARAMS)
    if params:
        for k, v in params.items():
            if k.lower() in ("powerstate", "registrationstate", "vmtoolsstate",
                             "faultstate", "maintenancemode"):
                merged_map[k.lower()] = v

    worst_state = 0  # 0 = OK
    summaries = []
    metric_values = {}

    for state_type, state in section_instance.items():
        key_lower = state_type.lower()
        monitoring_map = merged_map.get(key_lower, CONSTANTS_MAP.get(key_lower))

        if monitoring_map != None and state != None and state != "":
            if state in monitoring_map:
                level = monitoring_map[state]
                if type(level) == "int" and level > worst_state:
                    worst_state = level
                metric_values[key_lower] = float(level)
                summaries.append("%s %s" % (state_type, state))
            else:
                metric_values[key_lower] = 3.0
                summaries.append("%s %s" % (state_type, state))
        elif state == "" or state == None:
            summaries.append("%s -" % state_type)
        else:
            metric_values[key_lower] = 3.0
            summaries.append("%s %s" % (state_type, state))

    if worst_state >= 2:
        state_str = "CRIT"
    elif worst_state >= 1:
        state_str = "WARN"
    else:
        state_str = "OK"

    summary = ", ".join(summaries) if len(summaries) > 0 else "no state data"

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state_str,
            "metrics": metric_values,
            "details": summary,
        },
    }