def main(ctx, params):
    # Discovery mode
    if params.get("_discover"):
        res = ctx.run(["storcli", "/call", "show", "all", "J"], mutates=False)
        if res.rc != 0 or not res.stdout:
            return {"changed": False, "msg": "no cache vaults discovered", "data": {"discovery": []}}

        data = json.decode(res.stdout) if res.stdout else {}
        if type(data) != "dict":
            return {"changed": False, "msg": "no cache vaults discovered", "data": {"discovery": []}}

        discovery = []
        for controller_key in data.keys():
            if controller_key.startswith("/c") or controller_key.startswith("Controller"):
                ctrl_data = data.get(controller_key, {})
                if type(ctrl_data) == "dict":
                    cv_info = ctrl_data.get("CacheVaultInfo", [])
                    if type(cv_info) == "list":
                        for vault in cv_info:
                            if type(vault) == "dict":
                                ctrl_num = controller_key.replace("/c", "").replace("Controller", "")
                                item = "/c" + ctrl_num.strip()
                                state = vault.get("State", "")
                                capacitance_str = vault.get("Capacitance", "0%")
                                capacitance_val = 0.0
                                if capacitance_str.endswith("%"):
                                    num_part = capacitance_str[:-1]
                                    capacitance_val = float(num_part) if num_part.replace(".", "").isdigit() or num_part.replace("-", "").isdigit() else 0.0
                                repl = vault.get("Replacement required", "No")
                                needs_repl = repl.lower() != "no"
                                discovery.append({
                                    "item": item,
                                    "params": {},
                                    "metrics": ["capacitance"]
                                })
        return {"changed": False, "msg": "discovered %d cache vaults" % len(discovery),
                "data": {"discovery": discovery}}

    # Check mode
    item = params.get("item", "")

    res = ctx.run(["storcli", "/call", "show", "all", "J"], mutates=False)
    if res.rc != 0 or not res.stdout:
        return {"changed": False, "msg": "cannot fetch data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    data = json.decode(res.stdout) if res.stdout else {}
    if type(data) != "dict":
        return {"changed": False, "msg": "cannot parse JSON data", "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    vault = None
    for controller_key in data.keys():
        if controller_key.startswith("/c") or controller_key.startswith("Controller"):
            ctrl_num = controller_key.replace("/c", "").replace("Controller", "")
            ctrl_item = "/c" + ctrl_num.strip()
            if ctrl_item == item:
                ctrl_data = data.get(controller_key, {})
                if type(ctrl_data) == "dict":
                    cv_info = ctrl_data.get("CacheVaultInfo", [])
                    if type(cv_info) == "list" and len(cv_info) > 0:
                        vault = cv_info[0]
                        break

    if vault == None:
        return {"changed": False, "msg": "cache vault not found: %s" % item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}

    state_raw = vault.get("State", "Unknown")
    capacitance_str = vault.get("Capacitance", "0%")
    capacitance = 0.0
    if capacitance_str.endswith("%"):
        num_part = capacitance_str[:-1]
        capacitance = float(num_part) if num_part.replace(".", "").isdigit() or (num_part.startswith("-") and num_part[1:].replace(".", "").isdigit()) else 0.0
    repl = vault.get("Replacement required", "No")
    needs_repl = repl.lower() != "No"

    state = "OK" if state_raw == "Optimal" else "CRIT"

    msg_parts = [state_raw.capitalize()]
    msg_parts.append("Capacitance %d%%" % int(capacitance))
    if needs_repl:
        msg_parts.append("Replacement required")

    return {
        "changed": False,
        "msg": ", ".join(msg_parts),
        "data": {
            "state": state,
            "metrics": {"capacitance": capacitance},
            "details": "",
        },
    }