def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    driver = params.get("driver", "bridge")
    driver_options = params.get("driver_options", {})
    ipam_driver = params.get("ipam_driver")
    ipam_driver_options = params.get("ipam_driver_options", {})
    ipam_config = params.get("ipam_config", [])
    force = params.get("force", False)
    appends = params.get("appends", False)
    enable_ipv6 = params.get("enable_ipv6")
    internal = params.get("internal")
    scope = params.get("scope")
    attachable = params.get("attachable")
    labels = params.get("labels", {})
    connected = params.get("connected", [])
    timeout = params.get("timeout", 60)

    for cfg in ipam_config:
        if not cfg.get("subnet"):
            fail("ipam_config item missing required 'subnet' field")

    docker_host = params.get("docker_host", "unix:///var/run/docker.sock")
    if docker_host.startswith("tcp://") and params.get("tls", False):
        docker_host = "https://" + docker_host[6:]
    elif docker_host.startswith("tcp://"):
        docker_host = "http://" + docker_host[6:]

    def make_curl_args(path, method="GET", data=None):
        argv = ["curl", "-s", "-X", method, "--connect-timeout", str(timeout)]
        if method in ("POST", "PUT", "PATCH") and data != None:
            argv.extend(["-d", ctx.json.dumps(data)])
        if docker_host.startswith("https://"):
            if params.get("ca_path"):
                argv.extend(["--cacert", params["ca_path"]])
            else:
                argv.append("--insecure")
            if params.get("client_cert"):
                argv.extend(["--cert", params["client_cert"]])
            if params.get("client_key"):
                argv.extend(["--key", params["client_key"]])
        argv.append(docker_host + path)
        return argv

    def call_docker(method, path, data=None):
        argv = make_curl_args(path, method, data)
        res = ctx.run(argv, mutates=(method != "GET"))
        if res.skipped:
            return None
        if res.rc != 0:
            fail("Docker API error (" + method + " " + path + "): " + res.stderr)
        return ctx.json.loads(res.stdout)

    def list_networks():
        argv = make_curl_args("/networks", "GET")
        res = ctx.run(argv, mutates=False)
        if res.rc != 0:
            fail("Failed to list Docker networks: " + res.stderr)
        return ctx.json.loads(res.stdout)

    def find_network(name):
        nets = list_networks()
        for n in nets:
            if n.get("Name") == name:
                return n
        return None

    def inspect_network(net_id):
        argv = make_curl_args("/networks/" + net_id, "GET")
        res = ctx.run(argv, mutates=False)
        if res.rc != 0:
            return None
        return ctx.json.loads(res.stdout)

    existing = find_network(name)
    if existing:
        existing = inspect_network(existing["Id"])

    def normalize_ipam(configs):
        result = []
        if not configs:
            return result
        for cfg in configs:
            normalized = {}
            for k, v in cfg.items():
                if k == "AuxiliaryAddresses":
                    normalized["aux_addresses"] = v
                else:
                    normalized[k.lower()] = v
            result.append(normalized)
        return result

    def has_different_config(net):
        diff = []
        if driver and driver != net.get("Driver"):
            diff.append("driver")
        if driver_options:
            net_opts = net.get("Options", {})
            for k, v in driver_options.items():
                if net_opts.get(k) != v:
                    diff.append("driver_options." + k)
        if ipam_driver:
            net_ipam = net.get("IPAM", {})
            if net_ipam.get("Driver") != ipam_driver:
                diff.append("ipam_driver")
        if ipam_driver_options:
            net_ipam_opts = net_ipam.get("Options", {})
            if net_ipam_opts != ipam_driver_options:
                diff.append("ipam_driver_options")
        if ipam_config:
            net_ipam_configs = normalize_ipam(net.get("IPAM", {}).get("Config", []))
            if len(net_ipam_configs) != len(ipam_config):
                diff.append("ipam_config length mismatch")
            else:
                for i, cfg in enumerate(ipam_config):
                    found = False
                    for nc in net_ipam_configs:
                        match = True
                        for k, v in cfg.items():
                            if k == "aux_addresses":
                                if nc.get("aux_addresses") != v:
                                    match = False
                                    break
                            elif nc.get(k) != v:
                                match = False
                                break
                        if match:
                            found = True
                            break
                    if not found:
                        diff.append("ipam_config[" + str(i) + "] mismatch")
        if enable_ipv6 != None:
            if bool(enable_ipv6) != net.get("EnableIPv6", False):
                diff.append("enable_ipv6")
        if internal != None:
            if bool(internal) != net.get("Internal", False):
                diff.append("internal")
        if scope != None and scope != net.get("Scope"):
            diff.append("scope")
        if attachable != None:
            if bool(attachable) != net.get("Attachable", False):
                diff.append("attachable")
        if labels:
            net_labels = net.get("Labels", {})
            for k, v in labels.items():
                if net_labels.get(k) != v:
                    diff.append("labels." + k)
        return diff

    def get_connected_names(net):
        containers = net.get("Containers", {})
        return [c.get("Name") for c in containers.values()] if containers else []

    def disconnect_all(net_id):
        conts = get_connected_names(net)
        for c in conts:
            argv = make_curl_args("/networks/" + net_id + "/disconnect", "POST", {"Container": c})
            res = ctx.run(argv, mutates=True)
            if res.skipped:
                continue
            if res.rc != 0:
                fail("Failed to disconnect container " + c + ": " + res.stderr)

    def connect_container(net_id, container):
        argv = make_curl_args("/networks/" + net_id + "/connect", "POST", {"Container": container})
        res = ctx.run(argv, mutates=True)
        if res.skipped:
            return
        if res.rc != 0:
            fail("Failed to connect container " + container + ": " + res.stderr)

    changed = False
    msg = ""

    if state == "present":
        if force or existing and has_different_config(existing):
            if existing:
                disconnect_all(existing["Id"])
                argv = make_curl_args("/networks/" + existing["Id"], "DELETE")
                res = ctx.run(argv, mutates=True)
                if not res.skipped and res.rc != 0:
                    fail("Failed to remove network: " + res.stderr)
                changed = True
            existing = None

        if not existing:
            data = {
                "Name": name,
                "Driver": driver,
                "Options": driver_options,
                "CheckDuplicate": False
            }
            if enable_ipv6:
                data["EnableIPv6"] = True
            if internal:
                data["Internal"] = True
            if scope:
                data["Scope"] = scope
            if attachable:
                data["Attachable"] = True
            if labels:
                data["Labels"] = labels

            ipam_pools = []
            for cfg in ipam_config:
                pool = {"Subnet": cfg["subnet"]}
                if cfg.get("iprange"):
                    pool["IPRange"] = cfg["iprange"]
                if cfg.get("gateway"):
                    pool["Gateway"] = cfg["gateway"]
                if cfg.get("aux_addresses"):
                    pool["AuxiliaryAddresses"] = cfg["aux_addresses"]
                ipam_pools.append(pool)

            ipam_data = {}
            if ipam_driver:
                ipam_data["Driver"] = ipam_driver
            if ipam_driver_options:
                ipam_data["Options"] = ipam_driver_options
            if ipam_pools:
                ipam_data["Config"] = ipam_pools

            if ipam_data:
                data["IPAM"] = ipam_data

            argv = make_curl_args("/networks/create", "POST", data)
            res = ctx.run(argv, mutates=True)
            if res.skipped:
                changed = True
                msg = "would create network " + name
                return {"changed": True, "msg": msg}

            if res.rc != 0:
                fail("Failed to create network: " + res.stderr)
            resp = ctx.json.loads(res.stdout)
            existing = inspect_network(resp.get("Id"))
            changed = True
            msg = "created network " + name

        current_connected = get_connected_names(existing) if existing else []
        for c in connected:
            if c not in current_connected:
                connect_container(existing["Id"], c)
                changed = True
                if not msg:
                    msg = "connected containers to network " + name
                else:
                    msg += ", connected container " + c

        if not appends:
            for c in current_connected:
                if c not in connected:
                    argv = make_curl_args("/networks/" + existing["Id"] + "/disconnect", "POST", {"Container": c})
                    res = ctx.run(argv, mutates=True)
                    if res.skipped:
                        continue
                    if res.rc != 0:
                        fail("Failed to disconnect container " + c + ": " + res.stderr)
                    changed = True
                    if not msg:
                        msg = "disconnected containers from network " + name
                    else:
                        msg += ", disconnected container " + c

        if not changed:
            msg = "network " + name + " already exists with desired configuration"

        if not msg:
            msg = "network " + name + " state updated"

        return {"changed": changed, "msg": msg, "network": existing or {}}

    elif state == "absent":
        if existing:
            if force:
                disconnect_all(existing["Id"])
            argv = make_curl_args("/networks/" + existing["Id"], "DELETE")
            res = ctx.run(argv, mutates=True)
            if not res.skipped and res.rc != 0:
                fail("Failed to remove network: " + res.stderr)
            changed = True
            msg = "removed network " + name
        else:
            msg = "network " + name + " does not exist"
        return {"changed": changed, "msg": msg}

    fail("unsupported state: " + str(state))
