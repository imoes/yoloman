# Hyper-V VM summary — read-only Starlark check module
# Source: Checkmk checkmk.hyperv_vm_general
# Monitors a single Hyper-V VM summary section delivered by an SMB/powershell agent.

def _section_empty(section):
    if section == None:
        return True
    if len(section) == 0:
        return True
    return False


def _power_state_result(section, params):
    power_state = section.get("runtime.powerState")
    if not power_state:
        return {"state": "WARN", "msg": "State information is missing"}
    lower = power_state.lower()
    mapping = params.get("power_state", {})
    if mapping == None:
        mapping = {}
    default_mapping = DEFAULT_POWER_STATE
    if lower in mapping:
        state_value = mapping[lower]
    elif lower in default_mapping:
        state_value = default_mapping[lower]
    else:
        state_value = 3
    return {"state": _state_name(state_value), "msg": "State: " + power_state}


def _generation_result(section, params):
    generation = section.get("config.generation")
    if not generation:
        return {"state": "WARN", "msg": "VM Generation information is missing"}
    vm_gen_params = params.get("vm_generation", {})
    if vm_gen_params == None:
        vm_gen_params = {}
    if "expected_generation" not in vm_gen_params:
        return {"state": "WARN", "msg": "VM Generation information is missing"}
    expected = str(vm_gen_params["expected_generation"])
    expected_number = expected.replace("generation_", "")
    if generation != expected_number:
        state_value = vm_gen_params.get("state_if_not_expected", 1)
    else:
        state_value = 0
    return {"state": _state_name(state_value), "msg": "VM Generation: " + generation}


def _state_name(value):
    if value == 0:
        return "OK"
    if value == 1:
        return "WARN"
    if value == 2:
        return "CRIT"
    if value == 3:
        return "UNKNOWN"
    return "UNKNOWN"


def _worst_state(states):
    order = {"OK": 0, "WARN": 1, "CRIT": 2, "UNKNOWN": 3}
    worst = "OK"
    for s in states:
        if order.get(s, 3) > order.get(worst, 0):
            worst = s
    return worst


# Checkmk default params for this check (mirrors hyperv_vm_general_default_params)
DEFAULT_POWER_STATE = {
    "running": 0,
    "off": 2,
    "saved": 0,
    "paused": 1,
    "starting": 1,
}
DEFAULT_VM_GENERATION = {
    "expected_generation": "generation_2",
    "state_if_not_expected": 1,
}


def _read_section(ctx, params):
    # The Hyper-V agent delivers the section as a single JSON object (key/value pairs)
    # via the host's checkmk agent output. The vm_general converter yields a flat dict.
    section_path = params.get("section_path", "/var/lib/hyperv_vm_general/section.json")
    if not ctx.file_exists(section_path):
        return None
    content = ctx.file_read(section_path)
    if not content:
        return None
    return json.decode(content)


def main(ctx, params):
    if params.get("_discover"):
        section = _read_section(ctx, params)
        if _section_empty(section):
            return {"changed": False, "msg": "no Hyper-V VM section available", "data": {"discovery": []}}
        if not section.get("name"):
            return {"changed": False, "msg": "no Hyper-V VM name found", "data": {"discovery": []}}
        return {
            "changed": False,
            "msg": "discovered 1 Hyper-V VM",
            "data": {"discovery": [{"item": "", "params": {"power_state": {}, "vm_generation": {}}, "metrics": []}]},
        }

    section = _read_section(ctx, params)
    if _section_empty(section):
        return {
            "changed": False,
            "msg": "no Hyper-V VM section available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": "Hyper-V VM summary section not found"},
        }

    name = section.get("name")
    if not name:
        return {
            "changed": False,
            "msg": "VM name information is missing",
            "data": {"state": "WARN", "metrics": {}, "details": ""},
        }

    states = []
    msgs = []

    # VM name check (always OK)
    states.append("OK")
    msgs.append("VM name: " + name)

    # Power state check
    ps = _power_state_result(section, params)
    states.append(ps["state"])
    msgs.append(ps["msg"])

    # Host check
    running_on = section.get("runtime.host")
    if not running_on:
        states.append("WARN")
        msgs.append("Host information is missing")
    else:
        states.append("OK")
        msgs.append("Host: " + running_on)

    # VM generation check
    gen = _generation_result(section, params)
    states.append(gen["state"])
    msgs.append(gen["msg"])

    state = _worst_state(states)
    detail = " ; ".join(msgs)
    return {
        "changed": False,
        "msg": detail,
        "data": {"state": state, "metrics": {}, "details": detail},
    }