def main(ctx, params):
    if params.get("_discover"):
        sysOid = ctx.run([
            "snmpget", "-v2c",
            "-c", params.get("community", "public"),
            "-Oqv", params.get("host", "localhost"),
            ".1.3.6.1.2.1.1.2.0",
        ], mutates=False)
        if sysOid.rc != 0:
            return {"changed": False, "msg": "SNMP not reachable",
                    "data": {"discovery": []}}
        if not sysOid.stdout.startswith(".1.3.6.1.4.1.21796.3"):
            return {"changed": False, "msg": "not a Poseidon/Conext device",
                    "data": {"discovery": []}}
        walk = ctx.run([
            "snmpwalk", "-v2c",
            "-c", params.get("community", "public"),
            "-Oqn", params.get("host", "localhost"),
            ".1.3.6.1.4.1.21796.3.3.1.1",
        ], mutates=False)
        if walk.rc != 0:
            return {"changed": False, "msg": "poseidon_inputs not available",
                    "data": {"discovery": []}}
        discovery = []
        for line in walk.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            idx = parts[0][len(".1.3.6.1.4.1.21796.3.3.1.1") + 1:]
            if not idx:
                continue
            name_res = ctx.run([
                "snmpget", "-v2c",
                "-c", params.get("community", "public"),
                "-Oqv", params.get("host", "localhost"),
                ".1.3.6.1.4.1.21796.3.3.1.1.3." + idx,
            ], mutates=False)
            if name_res.rc == 0 and name_res.stdout:
                item = name_res.stdout.strip().strip('"')
            else:
                item = idx
            discovery.append({"item": item, "params": {},
                              "metrics": ["input_value", "input_alarm_state"]})
        return {"changed": False, "msg": "discovered %d poseidon_inputs" % len(discovery),
                "data": {"discovery": discovery}}

    item = params.get("item", "")
    idx = item
    # If item looks like a name rather than numeric index, find the matching OID
    walk = ctx.run([
        "snmpwalk", "-v2c",
        "-c", params.get("community", "public"),
        "-Oqn", params.get("host", "localhost"),
        ".1.3.6.1.4.1.21796.3.3.1.1.3",
    ], mutates=False)
    if walk.rc == 0:
        for line in walk.stdout.splitlines():
            parts = line.split(" ", 1)
            if len(parts) < 2:
                continue
            this_idx = parts[0][len(".1.3.6.1.4.1.21796.3.3.1.1.3") + 1:]
            val = parts[1].strip().strip('"')
            if val == item and this_idx:
                idx = this_idx
                break
    value_res = ctx.run([
        "snmpget", "-v2c",
        "-c", params.get("community", "public"),
        "-Oqv", params.get("host", "localhost"),
        ".1.3.6.1.4.1.21796.3.3.1.1.2." + idx,
    ], mutates=False)
    setup_res = ctx.run([
        "snmpget", "-v2c",
        "-c", params.get("community", "public"),
        "-Oqv", params.get("host", "localhost"),
        ".1.3.6.1.4.1.21796.3.3.1.1.4." + idx,
    ], mutates=False)
    alarm_state_res = ctx.run([
        "snmpget", "-v2c",
        "-c", params.get("community", "public"),
        "-Oqv", params.get("host", "localhost"),
        ".1.3.6.1.4.1.21796.3.3.1.1.5." + idx,
    ], mutates=False)
    if value_res.rc != 0 or setup_res.rc != 0 or alarm_state_res.rc != 0:
        return {"changed": False,
                "msg": "no such poseidon input: " + item,
                "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}}
    input_value_str = value_res.stdout.strip().strip('"')
    input_alarm_setup_str = setup_res.stdout.strip().strip('"')
    input_alarm_state_str = alarm_state_res.stdout.strip().strip('"')
    input_value = int(input_value_str) if input_value_str.lstrip("-").isdigit() else 3
    input_alarm_setup = int(input_alarm_setup_str) if input_alarm_setup_str.lstrip("-").isdigit() else 3
    input_alarm_state = int(input_alarm_state_str) if input_alarm_state_str.lstrip("-").isdigit() else 3
    alarm_setup = {0: "inactive", 1: "activeOff", 2: "activeOn", 3: "unkown"}
    input_values = {0: "off", 1: "on", 3: "unkown"}
    alarm_states = {0: "normal", 1: "alarm", 3: "unkown"}
    alarm_setup_value = input_alarm_setup
    txt1 = item + ": AlarmSetup: " + alarm_setup.get(alarm_setup_value, "unkown")
    state_value = input_alarm_state
    txt2 = "Alarm State: " + alarm_states.get(state_value, "unkown")
    state = "CRIT" if state_value == 1 else "OK"
    input_val = input_value
    txt3 = "Values " + input_values.get(input_val, "unkown")
    msg = txt1 + "; " + txt2 + "; " + txt3
    details = txt1 + "\n" + txt2 + "\n" + txt3
    return {"changed": False, "msg": msg,
            "data": {"state": state,
                     "metrics": {"input_value": input_val,
                                 "input_alarm_state": state_value},
                     "details": details}}