def main(ctx, params):
    if params.get("_discover"):
        return _discover(ctx, params)
    return _check(ctx, params)

# Checkmk defaults
_DEFAULT_STATUS = "active"
_STATE_IF_NOT_DEFAULT = 1  # WARN
_DEFAULT_MATCH_SERVICES = [
    {
        "service_name": "Guest Service Interface",
        "default_status": "inactive",
        "state_if_not_default": 0,  # OK
    }
]

def _discover(ctx, params):
    # Probe for Hyper-V guest environment
    res = ctx.run(["ls", "/sys/bus/vmbus"], mutates=False)
    if res.rc != 0:
        return {"changed": False, "msg": "no hyperv bus", "data": {"discovery": []}}
    
    # Check if we're a Hyper-V guest
    dmi = ctx.run(["cat", "/sys/class/dmi/id/sys_vendor"], mutates=False)
    if dmi.rc != 0:
        return {"changed": False, "msg": "no dmi", "data": {"discovery": []}}
    
    vendor = dmi.stdout.strip()
    if vendor != "Microsoft Corporation":
        return {"changed": False, "msg": "not hyper-v guest", "data": {"discovery": []}}
    
    # Check if integration services are present
    ic_dir = "/sys/bus/vmbus/devices"
    res2 = ctx.run(["ls", ic_dir], mutates=False)
    if res2.rc != 0:
        return {"changed": False, "msg": "no vmbus devices", "data": {"discovery": []}}
    
    # Single-service check: yield Service() if guest tools number exists
    # In our env, check for /sys/bus/vmbus/devices presence as the indicator
    if "guest.tools.number" in _read_section(ctx):
        return {
            "changed": False,
            "msg": "discovered Hyper-V VM integration services",
            "data": {
                "discovery": [
                    {
                        "item": "",
                        "params": {},
                        "metrics": [],
                    }
                ]
            },
        }
    
    return {"changed": False, "msg": "no integration services found", "data": {"discovery": []}}

def _read_section(ctx):
    section = {}
    # Read Hyper-V integration services from /sys/bus/vmbus/devices
    # Each device has a class_id that maps to integration services
    devices = ctx.run(["ls", "/sys/bus/vmbus/devices"], mutates=False)
    if devices.rc != 0:
        return section
    
    for device in devices.stdout.split():
        if device.startswith("vmbus_"):
            continue  # skip the bus itself
        
        class_id_file = "/sys/bus/vmbus/devices/" + device + "/class_id"
        class_id_res = ctx.run(["cat", class_id_file], mutates=False)
        if class_id_res.rc != 0:
            continue
        
        class_id = class_id_res.stdout.strip().lower()
        
        # Map class_id to service name
        # Key VMbus integration service GUIDs:
        # - VSS: 66938210-8820-4a0c-9d28-9d82da29d5c8 (guest.tools.service.VSS)
        # - Guest Services: 43392008-8d85-4b32-979d-04171c290118 (guest.tools.service.Guest Service Interface)
        # - Time Sync: 99938402-0000-0000-0000-000000000000 (guest.tools.service.Time Synchronization)
        # - Heartbeat: 99938401-0000-0000-0000-000000000000 (guest.tools.service.Heartbeat)
        # - KVP: 99938403-0000-0000-0000-000000000000 (guest.tools.service.Key-Value Pair Exchange)
        # - Shutdown: 99938400-0000-0000-0000-000000000000 (guest.tools.service.Shutdown)
        
        service_name = _guid_to_service(class_id)
        if service_name == "":
            continue
        
        section["guest.tools.service." + service_name.replace(" ", "_")] = "active"
    
    # Also read guest.tools.number if available
    tools_file = "/sys/bus/vmbus/devices/" 
    return section

def _guid_to_service(guid):
    mapping = {
        "66938210-8820-4a0c-9d28-9d82da29d5c8": "VSS",
        "43392008-8d85-4b32-979d-04171c290118": "Guest Service Interface",
        "99938402-0000-0000-0000-000000000000": "Time Synchronization",
        "99938401-0000-0000-0000-000000000000": "Heartbeat",
        "99938403-0000-0000-0000-000000000000": "Key-Value Pair Exchange",
        "99938400-0000-0000-0000-000000000000": "Shutdown",
    }
    return mapping.get(guid, "")

def _check(ctx, params):
    section = _read_section(ctx)
    if len(section) == 0:
        return {
            "changed": False,
            "msg": "no Hyper-V integration services found",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }
    
    global_default_status = str(params.get("default_status", _DEFAULT_STATUS))
    global_state_if_not_default = int(params.get("state_if_not_default", _STATE_IF_NOT_DEFAULT))
    
    # Build match_services dict
    match_services = {}
    for item in _DEFAULT_MATCH_SERVICES:
        service_name = item["service_name"]
        match_services[service_name] = {
            "default_status": str(item["default_status"]),
            "state_if_not_default": int(item["state_if_not_default"]),
        }
    
    # Override with params
    match_services_param = params.get("match_services", [])
    if type(match_services_param) == "list":
        for item in match_services_param:
            if type(item) == "dict":
                service_name = item["service_name"]
                match_services[service_name] = {
                    "default_status": str(item["default_status"]),
                    "state_if_not_default": int(item["state_if_not_default"]),
                }
    
    # Process each service
    results = _process_service_status(section, match_services, global_default_status, global_state_if_not_default)
    
    if len(results) == 0:
        return {
            "changed": False,
            "msg": "no integration services to check",
            "data": {
                "state": "UNKNOWN",
                "metrics": {},
                "details": "",
            },
        }
    
    # Aggregate states - worst wins
    worst_state = "OK"
    summaries = []
    for r in results:
        summaries.append(r["summary"])
        if r["state"] == "CRITICAL":
            worst_state = "CRITICAL"
        elif r["state"] == "WARN" and worst_state != "CRITICAL":
            worst_state = "WARN"
        elif r["state"] == "UNKNOWN" and worst_state == "OK":
            worst_state = "UNKNOWN"
    
    return {
        "changed": False,
        "msg": "; ".join(summaries),
        "data": {
            "state": worst_state,
            "metrics": {},
            "details": "\n".join(summaries),
        },
    }

def _process_service_status(section, match_services, global_default_status, global_state_if_not_default):
    results = []
    for key in section:
        if not key.startswith("guest.tools.service"):
            continue
        service = key.replace("guest.tools.service.", "").replace("_", " ")
        if "VSS" in service:
            service = "VSS (Volume Shadow Copy Service)"
        service_status = str(section[key])
        
        if service in match_services:
            service_settings = match_services[service]
            default_status = service_settings["default_status"]
            state_if_not_default = service_settings["state_if_not_default"]
        else:
            default_status = global_default_status
            state_if_not_default = global_state_if_not_default
        
        if service_status == default_status:
            state = "OK"
        elif service_status in ["active", "inactive"]:
            state = _state_to_str(state_if_not_default)
        else:
            state = "UNKNOWN"
        
        results.append({"state": state, "summary": service + ": " + service_status})
    
    return results

def _state_to_str(state_int):
    if state_int == 0:
        return "OK"
    elif state_int == 1:
        return "WARN"
    elif state_int == 2:
        return "CRITICAL"
    elif state_int == 3:
        return "UNKNOWN"
    return "UNKNOWN"