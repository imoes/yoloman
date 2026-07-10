def main(ctx, params):
    if params.get("_discover"):
        # Try to get agent section data
        res = ctx.run(["cmk", "--agent", "--section", "3par_ports"], mutates=False)
        if res.rc != 0 or not res.stdout.strip():
            # Try fallback methods
            raw_res = ctx.run(["cmk", "--show-output"], mutates=False)
            output = raw_res.stdout.strip() if raw_res.rc == 0 else ""
            if not output:
                fallback_res = ctx.run(["cmk", "--agent-output"], mutates=False)
                output = fallback_res.stdout.strip() if fallback_res.rc == 0 else ""
            
            # If still no output, return empty discovery
            if not output:
                return {
                    "changed": False,
                    "msg": "discovered 0 ports",
                    "data": {"discovery": []}
                }
        else:
            output = res.stdout.strip()
        
        data = json_load(output)
        members = data.get("members", [])
        items = []
        for port in members:
            if type(port) != "dict":
                continue
            protocol = port.get("protocol", 0)
            port_type = port.get("type", 0)
            if port_type != 3 and protocol in [1,2,3,4,5,6]:
                pos = port.get("portPos", {})
                node = pos.get("node", 0)
                slot = pos.get("slot", 0)
                cardPort = pos.get("cardPort", 0)
                PROTOCOLS = {1:"FC",2:"iSCSI",3:"FCOE",4:"IP",5:"SAS",6:"NVMe"}
                proto_name = PROTOCOLS.get(protocol, "Unknown")
                name = "%s Node %s Slot %s Port %s" % (proto_name, node, slot, cardPort)
                items.append({
                    "item": name,
                    "params": {},
                    "metrics": []
                })
        return {
            "changed": False,
            "msg": "discovered %d ports" % len(items),
            "data": {"discovery": items}
        }

    # Check mode
    item = params.get("item", "")
    if item == "":
        return {
            "changed": False,
            "msg": "no item specified",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Get port data
    res = ctx.run(["cmk", "--agent", "--section", "3par_ports"], mutates=False)
    if res.rc != 0 or not res.stdout.strip():
        return {
            "changed": False,
            "msg": "agent section 3par_ports not available",
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    data = json_load(res.stdout.strip())
    members = data.get("members", [])
    port_data = None
    for port in members:
        if type(port) != "dict":
            continue
        protocol = port.get("protocol", 0)
        port_type = port.get("type", 0)
        if port_type != 3 and protocol in [1,2,3,4,5,6]:
            pos = port.get("portPos", {})
            node = pos.get("node", 0)
            slot = pos.get("slot", 0)
            cardPort = pos.get("cardPort", 0)
            PROTOCOLS = {1:"FC",2:"iSCSI",3:"FCOE",4:"IP",5:"SAS",6:"NVMe"}
            proto_name = PROTOCOLS.get(protocol, "Unknown")
            name = "%s Node %s Slot %s Port %s" % (proto_name, node, slot, cardPort)
            if name == item:
                port_data = port
                break

    if port_data == None:
        return {
            "changed": False,
            "msg": "port not found: " + item,
            "data": {"state": "UNKNOWN", "metrics": {}, "details": ""}
        }

    # Parse port data according to Checkmk logic
    LINKS = {
        1: "CONFIG_WAIT",
        2: "ALPA_WAIT",
        3: "LOGIN_WAIT",
        4: "READY",
        5: "LOSS_SYNC",
        6: "ERROR_STATE",
        7: "XXX",
        8: "NONPARTICIPATE",
        9: "COREDUMP",
        10: "OFFLINE",
        11: "FWDEAD",
        12: "IDLE_FOR_RESET",
        13: "DHCP_IN_PROGRESS",
        14: "PENDING_RESET"
    }
    FAILOVERS = {
        1: "NONE",
        2: "FAILOVER_PENDING",
        3: "FAILED_OVER",
        4: "ACTIVE",
        5: "ACTIVE_DOWN",
        6: "ACTIVE_FAILED",
        7: "FAILBACK_PENDING"
    }
    MODES = {
        1: "SUSPENDED",
        2: "TARGET",
        3: "INITIATOR",
        4: "PEER"
    }

    # Default levels from Checkmk
    default_levels = {
        "1_link": 1,
        "2_link": 1,
        "3_link": 1,
        "4_link": 0,
        "5_link": 2,
        "6_link": 2,
        "7_link": 1,
        "8_link": 0,
        "9_link": 1,
        "10_link": 1,
        "11_link": 1,
        "12_link": 1,
        "13_link": 1,
        "14_link": 1,
        "1_fail": 0,
        "2_fail": 2,
        "3_fail": 2,
        "4_fail": 2,
        "5_fail": 2,
        "6_fail": 2,
        "7_fail": 1,
    }

    # Use params if provided, else defaults
    levels = {}
    for k in default_levels.keys():
        levels[k] = params.get(k, default_levels[k])

    state = "OK"
    summary_parts = []
    metrics = {}

    # Label
    label = port_data.get("label")
    if label != None:
        summary_parts.append("Label: %s" % label)

    # Link state
    port_state = port_data.get("linkState")
    if port_state != None:
        state_str = LINKS.get(port_state, "UNKNOWN")
        level_key = "%s_link" % port_state
        level_val = levels.get(level_key, 1)
        # Map level_val to State: 0=OK, 1=WARN, 2=CRIT
        if level_val == 0:
            port_state_value = 0
        elif level_val == 1:
            port_state_value = 1
        else:  # level_val == 2
            port_state_value = 2
        state = "CRIT" if port_state_value == 2 else ("WARN" if port_state_value == 1 else "OK")
        summary_parts.append(state_str)
        metrics["link_state"] = port_state

    # PortWWN
    portWWN = port_data.get("portWWN")
    if portWWN != None:
        summary_parts.append("portWWN: %s" % portWWN)
        metrics["port_wwn"] = portWWN

    # Mode
    port_mode = port_data.get("mode")
    if port_mode != None:
        mode_str = MODES.get(port_mode, "UNKNOWN")
        summary_parts.append("Mode: %s" % mode_str)
        metrics["mode"] = port_mode

    # Failover state
    port_failover = port_data.get("failoverState")
    if port_failover != None:
        failover_str = FAILOVERS.get(port_failover, "UNKNOWN")
        failover_key = "%s_fail" % port_failover
        failover_level = levels.get(failover_key, 1)
        if failover_level == 0:
            failover_state_value = 0
        elif failover_level == 1:
            failover_state_value = 1
        else:  # failover_level == 2
            failover_state_value = 2
        failover_state = "CRIT" if failover_state_value == 2 else ("WARN" if failover_state_value == 1 else "OK")
        if failover_state == "CRIT":
            state = "CRIT"
        elif failover_state == "WARN" and state == "OK":
            state = "WARN"
        summary_parts.append("Failover: %s" % failover_str)
        metrics["failover_state"] = port_failover

    # Combine summary
    summary = ", ".join(summary_parts) if summary_parts else item

    return {
        "changed": False,
        "msg": summary,
        "data": {
            "state": state,
            "metrics": metrics,
            "details": ""
        }
    }


# Helper to parse JSON - simple string-based parser for dict/list
def json_load(s):
    s = s.strip()
    if s.startswith("{"):
        return _parse_object(s)
    elif s.startswith("["):
        return _parse_array(s)
    else:
        fail("JSON must start with { or [")


def _parse_object(s):
    result = {}
    s = s[1:].strip()
    if s.startswith("}"):
        return result
    while True:
        # Expect key
        s = s.lstrip()
        if not s or s[0] != '"':
            fail("expected key")
        key, s = _parse_string(s)
        s = s.lstrip()
        if not s or s[0] != ':':
            fail("expected :")
        s = s[1:].strip()
        value, s = _json_value(s)
        result[key] = value
        s = s.lstrip()
        if not s:
            fail("unclosed object")
        if s[0] == '}':
            return result
        if s[0] == ',':
            s = s[1:].strip()
        else:
            fail("expected , or }")


def _parse_array(s):
    result = []
    s = s[1:].strip()
    if s.startswith("]"):
        return result
    while True:
        value, s = _json_value(s)
        result.append(value)
        s = s.lstrip()
        if not s:
            fail("unclosed array")
        if s[0] == ']':
            return result
        if s[0] == ',':
            s = s[1:].strip()
        else:
            fail("expected , or ]")


def _json_value(s):
    s = s.lstrip()
    if s.startswith('{'):
        return _parse_object(s)
    elif s.startswith('['):
        return _parse_array(s)
    elif s.startswith('"'):
        return _parse_string(s)
    elif s.startswith('true'):
        return True, s[4:]
    elif s.startswith('false'):
        return False, s[5:]
    elif s.startswith('null'):
        return None, s[4:]
    elif s.startswith('-') or (s[0].isdigit() and not s[0].isalpha()):
        return _parse_number(s)
    else:
        fail("invalid value")


def _parse_string(s):
    if not s.startswith('"'):
        fail("expected string")
    i = 1
    result = ""
    while i < len(s):
        c = s[i]
        if c == '"':
            return result, s[i+1:]
        elif c == '\\':
            i += 1
            if i < len(s):
                nc = s[i]
                if nc == '"':
                    result += '"'
                elif nc == '\\':
                    result += '\\'
                elif nc == 'b':
                    result += '\b'
                elif nc == 'f':
                    result += '\f'
                elif nc == 'n':
                    result += '\n'
                elif nc == 'r':
                    result += '\r'
                elif nc == 't':
                    result += '\t'
                else:
                    result += nc
            i += 1
        else:
            result += c
            i += 1
    fail("unclosed string")


def _parse_number(s):
    i = 0
    if s.startswith('-'):
        i = 1
    while i < len(s) and s[i].isdigit():
        i += 1
    if i < len(s) and s[i] == '.':
        i += 1
        while i < len(s) and s[i].isdigit():
            i += 1
    if i < len(s) and (s[i] == 'e' or s[i] == 'E'):
        i += 1
        if i < len(s) and (s[i] == '+' or s[i] == '-'):
            i += 1
        while i < len(s) and s[i].isdigit():
            i += 1
    num_str = s[:i]
    rest = s[i:]
    if '.' in num_str or 'e' in num_str.lower():
        return float(num_str), rest
    else:
        return int(num_str), rest
