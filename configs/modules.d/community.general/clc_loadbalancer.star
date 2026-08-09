def main(ctx, params):
    # Extract parameters
    name = params["name"]
    alias = params["alias"]
    location = params["location"]
    description = params.get("description", name)
    port = params.get("port")
    method = params.get("method")
    persistence = params.get("persistence")
    nodes = params.get("nodes", [])
    status = params.get("status", "enabled")
    state = params.get("state", "present")

    # Validate required parameters
    if not name or not alias or not location:
        fail("Missing required parameters: name, alias, location must be provided")

    # State validation
    if state not in ["present", "absent", "port_absent", "nodes_present", "nodes_absent"]:
        fail("Invalid state: " + state + ". Must be one of: present, absent, port_absent, nodes_present, nodes_absent")

    # Port validation
    if port != None and str(port) not in ["80", "443"]:
        fail("Invalid port: " + str(port) + ". Must be 80 or 443")

    is_check_mode = ctx.check_mode

    # Get environment variables via ctx.facts() simulation
    v2_api_token = ctx.facts().get("CLC_V2_API_TOKEN")
    clc_alias = ctx.facts().get("CLC_ACCT_ALIAS")
    v2_api_username = ctx.facts().get("CLC_V2_API_USERNAME")
    v2_api_passwd = ctx.facts().get("CLC_V2_API_PASSWD")

    # Basic auth check
    if not (v2_api_token != None and clc_alias != None) and not (v2_api_username != None and v2_api_passwd != None):
        fail("You must set either (CLC_V2_API_TOKEN and CLC_ACCT_ALIAS) or (CLC_V2_API_USERNAME and CLC_V2_API_PASSWD) environment variables")

    changed = False
    msg = ""
    result_lb = {}

    # Helper: list loadbalancers via clc-cli
    def list_loadbalancers():
        res = ctx.run(["clc-cli", "loadbalancer", "list", "--alias", alias, "--location", location], mutates=False)
        if res.rc != 0:
            fail("Failed to list loadbalancers: " + res.stderr)
        return res.stdout  # Assume clc-cli returns structured text (e.g., JSON-like parseable manually)

    # Helper: get lb_id by name (simple text parser)
    def get_lb_id_by_name(lb_name, lb_text):
        for line in lb_text.splitlines():
            parts = line.split()
            if len(parts) >= 3 and parts[0] == lb_name:
                return parts[1]  # assumes format: "name id status"
        return None

    # Helper: list pools
    def list_pools(lb_id):
        res = ctx.run(["clc-cli", "pool", "list", "--alias", alias, "--location", location, "--lb-id", lb_id], mutates=False)
        if res.rc != 0:
            fail("Failed to list pools: " + res.stderr)
        return res.stdout

    # Helper: get pool_id by port
    def get_pool_id_by_port(port_val, pool_text):
        for line in pool_text.splitlines():
            parts = line.split()
            if len(parts) >= 2 and parts[0] == str(port_val):
                return parts[1]
        return None

    # Helper: list nodes
    def list_nodes(lb_id, pool_id):
        res = ctx.run(["clc-cli", "node", "list", "--alias", alias, "--location", location, "--lb-id", lb_id, "--pool-id", pool_id], mutates=False)
        if res.rc != 0:
            fail("Failed to list nodes: " + res.stderr)
        return res.stdout

    # Helper: run CLC CLI command
    def clc_run(cmd):
        return ctx.run(["clc-cli"] + cmd, mutates=True, ok_codes=[0])

    # === STATE: present ===
    if state == "present":
        lb_text = list_loadbalancers()
        lb_id = get_lb_id_by_name(name, lb_text)

        if lb_id == None:
            if is_check_mode:
                changed = True
                msg = "would create loadbalancer '" + name + "'"
                return {"changed": True, "msg": msg}
            clc_run(["loadbalancer", "create", "--alias", alias, "--location", location,
                     "--name", name, "--description", description, "--status", status])
            changed = True
            msg = "created loadbalancer '" + name + "'"
            lb_text = list_loadbalancers()
            lb_id = get_lb_id_by_name(name, lb_text)
            result_lb = {"name": name, "id": lb_id, "status": status}
        else:
            result_lb = {"name": name, "id": lb_id, "status": status}

        # Handle port and nodes if port is specified
        if port != None:
            pool_text = list_pools(lb_id)
            pool_id = get_pool_id_by_port(port, pool_text)

            if pool_id == None:
                if is_check_mode:
                    changed = True
                    msg = "would create pool for port " + str(port)
                    return {"changed": True, "msg": msg}
                clc_run(["pool", "create", "--alias", alias, "--location", location,
                         "--lb-id", lb_id, "--port", str(port),
                         "--method", method or "roundRobin",
                         "--persistence", persistence or "standard"])
                changed = True
                msg = "created pool for port " + str(port)
                pool_text = list_pools(lb_id)
                pool_id = get_pool_id_by_port(port, pool_text)

            # Handle nodes if provided
            if nodes != [] and pool_id != None:
                node_text = list_nodes(lb_id, pool_id)
                current_set = {}
                for line in node_text.splitlines():
                    parts = line.split()
                    if len(parts) >= 2:
                        key = parts[0] + ":" + parts[1]
                        current_set[key] = True

                for node in nodes:
                    ip = str(node.get("ipAddress"))
                    pport = str(node.get("privatePort"))
                    key = ip + ":" + pport
                    if key not in current_set:
                        status_val = str(node.get("status", "enabled"))
                        if is_check_mode:
                            changed = True
                            msg = "would add node " + ip + ":" + pport
                            return {"changed": True, "msg": msg}
                        clc_run(["node", "add", "--alias", alias, "--location", location,
                                 "--lb-id", lb_id, "--pool-id", pool_id,
                                 "--ip-address", ip,
                                 "--private-port", pport,
                                 "--status", status_val])
                        changed = True
                        msg = "added node " + ip + ":" + pport

    # === STATE: absent ===
    elif state == "absent":
        lb_text = list_loadbalancers()
        lb_id = get_lb_id_by_name(name, lb_text)

        if lb_id != None:
            if is_check_mode:
                changed = True
                msg = "would delete loadbalancer '" + name + "'"
                return {"changed": True, "msg": msg}
            clc_run(["loadbalancer", "delete", "--alias", alias, "--location", location, "--lb-id", lb_id])
            changed = True
            msg = "deleted loadbalancer '" + name + "'"

    # === STATE: port_absent ===
    elif state == "port_absent":
        lb_text = list_loadbalancers()
        lb_id = get_lb_id_by_name(name, lb_text)
        if lb_id == None:
            msg = "Loadbalancer '" + name + "' does not exist"
            return {"changed": False, "msg": msg}
        pool_text = list_pools(lb_id)
        pool_id = get_pool_id_by_port(port, pool_text)
        if pool_id == None:
            msg = "Pool for port " + str(port) + " does not exist"
            return {"changed": False, "msg": msg}
        if is_check_mode:
            changed = True
            msg = "would delete pool for port " + str(port)
            return {"changed": True, "msg": msg}
        clc_run(["pool", "delete", "--alias", alias, "--location", location, "--lb-id", lb_id, "--pool-id", pool_id])
        changed = True
        msg = "deleted pool for port " + str(port)

    # === STATE: nodes_present ===
    elif state == "nodes_present":
        lb_text = list_loadbalancers()
        lb_id = get_lb_id_by_name(name, lb_text)
        if lb_id == None:
            fail("Loadbalancer '" + name + "' does not exist")
        pool_text = list_pools(lb_id)
        pool_id = get_pool_id_by_port(port, pool_text)
        if pool_id == None:
            fail("Pool for port " + str(port) + " does not exist")
        node_text = list_nodes(lb_id, pool_id)

        current_set = {}
        for line in node_text.splitlines():
            parts = line.split()
            if len(parts) >= 2:
                current_set[parts[0] + ":" + parts[1]] = True

        for node in nodes or []:
            ip = str(node.get("ipAddress"))
            pport = str(node.get("privatePort"))
            key = ip + ":" + pport
            if key not in current_set:
                if is_check_mode:
                    changed = True
                    msg = "would add node " + ip + ":" + pport
                    return {"changed": True, "msg": msg}
                status_val = str(node.get("status", "enabled"))
                clc_run(["node", "add", "--alias", alias, "--location", location,
                         "--lb-id", lb_id, "--pool-id", pool_id,
                         "--ip-address", ip,
                         "--private-port", pport,
                         "--status", status_val])
                changed = True
                msg = "added node " + ip + ":" + pport

    # === STATE: nodes_absent ===
    elif state == "nodes_absent":
        lb_text = list_loadbalancers()
        lb_id = get_lb_id_by_name(name, lb_text)
        if lb_id == None:
            fail("Loadbalancer '" + name + "' does not exist")
        pool_text = list_pools(lb_id)
        pool_id = get_pool_id_by_port(port, pool_text)
        if pool_id == None:
            fail("Pool for port " + str(port) + " does not exist")
        node_text = list_nodes(lb_id, pool_id)

        for line in node_text.splitlines():
            parts = line.split()
            if len(parts) >= 2:
                ip = parts[0]
                pport = parts[1]
                for node in nodes or []:
                    if str(node.get("ipAddress")) == ip and str(node.get("privatePort")) == pport:
                        if is_check_mode:
                            changed = True
                            msg = "would remove node " + ip + ":" + pport
                            return {"changed": True, "msg": msg}
                        clc_run(["node", "remove", "--alias", alias, "--location", location,
                                 "--lb-id", lb_id, "--pool-id", pool_id,
                                 "--ip-address", ip,
                                 "--private-port", pport])
                        changed = True
                        msg = "removed node " + ip + ":" + pport

    if not changed:
        msg = "no changes needed"
    return {"changed": changed, "msg": msg, "loadbalancer": result_lb}
