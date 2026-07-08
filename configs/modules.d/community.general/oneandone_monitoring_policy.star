def main(ctx, params):
    # Validate state
    state = params.get("state", "present")
    if state not in ["present", "absent", "update"]:
        fail("state must be one of: present, absent, update")

    # Required params per state
    if state == "present":
        for required in ["name", "agent", "email", "thresholds", "ports", "processes"]:
            if params.get(required) == None:
                fail(required + " parameter is required for state=present")
    elif state == "absent":
        if params.get("name") == None:
            fail("name parameter is required for state=absent")
    elif state == "update":
        if params.get("monitoring_policy") == None:
            fail("monitoring_policy parameter is required for state=update")

    # Validate auth_token (we can't use it but check it's provided)
    auth_token = params.get("auth_token")
    if auth_token == None:
        fail("auth_token parameter is required")

    # Validate thresholds structure if present
    thresholds = params.get("thresholds", [])
    if type(thresholds) != "list":
        fail("thresholds must be a list")
    for threshold in thresholds:
        if type(threshold) != "dict":
            fail("each threshold must be a dict")
        if len(threshold.keys()) == 0:
            fail("threshold must have exactly one key")
        entity = list(threshold.keys())[0]
        if entity not in ["cpu", "ram", "disk", "internal_ping", "transfer"]:
            fail("invalid threshold entity: " + entity)
        if type(threshold[entity]) != "dict":
            fail("threshold value must be a dict with warning and critical keys")

    # Validate ports structure if present
    ports = params.get("ports", [])
    if type(ports) != "list":
        fail("ports must be a list")
    for port in ports:
        if type(port) != "dict":
            fail("each port must be a dict")
        for key in ["protocol", "port", "alert_if", "email_notification"]:
            if port.get(key) == None:
                fail("port missing required key: " + key)
        if port["protocol"] not in ["TCP", "UDP"]:
            fail("port protocol must be TCP or UDP")
        if port["alert_if"] not in ["RESPONDING", "NOT_RESPONDING"]:
            fail("port alert_if must be RESPONDING or NOT_RESPONDING")
        port_num = port.get("port")
        if type(port_num) != "int" or port_num < 1 or port_num > 65535:
            fail("port must be an integer between 1 and 65535")

    # Validate processes structure if present
    processes = params.get("processes", [])
    if type(processes) != "list":
        fail("processes must be a list")
    for process in processes:
        if type(process) != "dict":
            fail("each process must be a dict")
        for key in ["process", "alert_if"]:
            if process.get(key) == None:
                fail("process missing required key: " + key)
        if process["alert_if"] not in ["RUNNING", "NOT_RUNNING"]:
            fail("process alert_if must be RUNNING or NOT_RUNNING")

    # Check mode handling
    if ctx.check_mode:
        return {
            "changed": True,
            "msg": "would configure 1&1 monitoring policy in check mode"
        }

    # Fail with clear message since HTTP API access isn't available
    fail("this module requires HTTP API access to 1&1, which is not available in this Starlark runtime. Please use the original Ansible module or implement HTTP support via ctx.run() with curl/wget.")
