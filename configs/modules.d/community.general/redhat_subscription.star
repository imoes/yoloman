def main(ctx, params):
    state = params.get("state", "present")
    force_register = params.get("force_register", False)
    auto_attach = params.get("auto_attach", False)
    pool_ids = params.get("pool_ids", [])
    pool = params.get("pool", "^$")
    syspurpose = params.get("syspurpose")
    
    # Check registration status
    res = ctx.run(["subscription-manager", "identity"], mutates=False)
    is_registered = res.rc == 0
    
    if state == "absent":
        if not is_registered:
            return {"changed": False, "msg": "system is not registered"}
        res = ctx.run(["subscription-manager", "unregister"], mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would unregister system"}
        if res.rc != 0:
            fail("failed to unregister: " + res.stderr)
        return {"changed": True, "msg": "unregistered system"}
    
    # State == "present"
    registration_needed = not is_registered or force_register
    
    if registration_needed:
        # Build registration command
        args = ["subscription-manager", "register"]
        
        if force_register:
            args.append("--force")
        
        org_id = params.get("org_id")
        if org_id:
            args.extend(["--org", org_id])
        
        if auto_attach:
            args.append("--auto-attach")
        
        consumer_type = params.get("consumer_type")
        if consumer_type:
            args.extend(["--type", consumer_type])
        
        consumer_name = params.get("consumer_name")
        if consumer_name:
            args.extend(["--name", consumer_name])
        
        consumer_id = params.get("consumer_id")
        if consumer_id:
            args.extend(["--consumerid", consumer_id])
        
        environment = params.get("environment")
        if environment:
            args.extend(["--environment", environment])
        
        activationkey = params.get("activationkey")
        token = params.get("token")
        username = params.get("username")
        password = params.get("password")
        
        if activationkey:
            args.extend(["--activationkey", activationkey])
        elif token:
            args.extend(["--token", token])
        elif username:
            args.extend(["--username", username])
            if password:
                args.extend(["--password", password])
        else:
            fail("authentication required: provide username/password, token, or activationkey/org_id")
        
        release = params.get("release")
        if release:
            args.extend(["--release", release])
        
        # Configure server options if provided
        configure_server_options(args, params)
        
        res = ctx.run(args, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would register system"}
        if res.rc != 0:
            fail("failed to register: " + res.stderr)
    
    # Subscribe to pools if needed
    subscribed_pool_ids = get_subscribed_pool_ids(ctx)
    
    # Check if we need to attach pools
    if pool_ids and len(pool_ids) > 0:
        # Convert pool_ids list to dict: string -> quantity or None
        pool_dict = {}
        for item in pool_ids:
            if type(item) == "string":
                pool_dict[item] = None
            else:
                # Assume it's a dict-like structure - get first key-value
                for key in item:
                    pool_dict[str(key)] = item[key]
                    break
        
        # Get available pools
        available_pools = get_available_pool_ids(ctx)
        
        missing_pools = {}
        for pid, quantity in pool_dict.items():
            if pid in available_pools:
                # Check if already attached with correct quantity
                current_qty = subscribed_pool_ids.get(pid, 0)
                if quantity == None:
                    quantity = 1
                if current_qty != quantity:
                    missing_pools[pid] = quantity
            # else: pool not available, but we'll try anyway (CLI will fail)
        
        if len(missing_pools) > 0:
            if ctx.check_mode:
                return {"changed": True, "msg": "would attach pools", "data": {"subscribed_pool_ids": list(missing_pools.keys())}}
            
            for pid, quantity in missing_pools.items():
                args = ["subscription-manager", "attach", "--pool", pid]
                if quantity != None:
                    args.extend(["--quantity", str(quantity)])
                res = ctx.run(args, mutates=True)
                if res.rc != 0:
                    fail("failed to attach pool " + pid + ": " + res.stderr)
            
            subscribed_pool_ids = get_subscribed_pool_ids(ctx)
    elif pool and pool != "^$":
        # Deprecated pool option - use pool_ids instead
        fail("the 'pool' option is deprecated; use 'pool_ids' instead")
    
    # Handle syspurpose
    if syspurpose != None:
        changed_syspurpose = handle_syspurpose(ctx, syspurpose)
        if changed_syspurpose:
            return {"changed": True, "msg": "updated syspurpose attributes", "data": {"subscribed_pool_ids": subscribed_pool_ids}}
    
    if registration_needed:
        return {"changed": True, "msg": "registered system", "data": {"subscribed_pool_ids": subscribed_pool_ids}}
    
    if len(pool_ids) > 0 and len(pool_ids) != len(subscribed_pool_ids):
        return {"changed": True, "msg": "updated subscriptions", "data": {"subscribed_pool_ids": subscribed_pool_ids}}
    
    return {"changed": False, "msg": "system already registered", "data": {"subscribed_pool_ids": subscribed_pool_ids}}


def configure_server_options(args, params):
    server_opts = [
        "server_hostname", "server_port", "server_prefix", "server_insecure",
        "rhsm_baseurl", "rhsm_repo_ca_cert",
        "server_proxy_hostname", "server_proxy_port", "server_proxy_scheme",
        "server_proxy_user", "server_proxy_password"
    ]
    
    for opt in server_opts:
        val = params.get(opt)
        if val != None:
            cli_opt = "--" + opt.replace("_", ".", 1) + "=" + str(val)
            args.append(cli_opt)


def get_subscribed_pool_ids(ctx):
    res = ctx.run(["subscription-manager", "list", "--consumed"], mutates=False)
    if res.rc != 0:
        return {}
    
    subscribed = {}
    lines = res.stdout.split("\n")
    current_pool_id = None
    
    for line in lines:
        line = line.strip()
        if line.startswith("PoolId:") or line.startswith("Pool ID:"):
            current_pool_id = line.split(":", 1)[1].strip()
        elif line.startswith("QuantityUsed:") and current_pool_id != None:
            qty = int(line.split(":", 1)[1].strip())
            subscribed[current_pool_id] = qty
            current_pool_id = None
    
    return subscribed


def get_available_pool_ids(ctx):
    res = ctx.run(["subscription-manager", "list", "--available"], mutates=False)
    if res.rc != 0:
        return {}
    
    available = {}
    lines = res.stdout.split("\n")
    current_pool_id = None
    
    for line in lines:
        line = line.strip()
        if line.startswith("PoolId:") or line.startswith("Pool ID:"):
            current_pool_id = line.split(":", 1)[1].strip()
            available[current_pool_id] = True
    
    return available


def handle_syspurpose(ctx, syspurpose):
    syspurpose_file = "/etc/rhsm/syspurpose/syspurpose.json"
    
    content = {}
    if syspurpose.get("role") != None:
        content["role"] = str(syspurpose["role"])
    if syspurpose.get("usage") != None:
        content["usage"] = str(syspurpose["usage"])
    if syspurpose.get("service_level_agreement") != None:
        content["service_level_agreement"] = str(syspurpose["service_level_agreement"])
    if syspurpose.get("addons") != None:
        content["addons"] = [str(x) for x in syspurpose["addons"]]
    
    if ctx.file_exists(syspurpose_file):
        existing_content = ctx.file_read(syspurpose_file)
        if existing_content == str(content):
            return False
    
    json_content = "{\n"
    items = list(content.items())
    for i, (k, v) in enumerate(items):
        json_content += "  \"" + k + "\": " + ("\"" + v + "\"" if type(v) == "string" else str(v).lower() if type(v) == "bool" else str(v))
        if i < len(items) - 1:
            json_content += ",\n"
        else:
            json_content += "\n"
    json_content += "}"
    
    changed = ctx.file_write(syspurpose_file, json_content)
    
    if syspurpose.get("sync", False) == True:
        res = ctx.run(["subscription-manager", "syspurpose"], mutates=True)
        if res.skipped:
            return True
        if res.rc != 0:
            fail("failed to sync syspurpose: " + res.stderr)
    
    return changed
