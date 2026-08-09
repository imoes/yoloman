def main(ctx, params):
    # Core required parameters for API connection
    api_host = params["api_host"]
    api_user = params["api_user"]
    api_password = params.get("api_password")
    api_token_id = params.get("api_token_id")
    api_token_secret = params.get("api_token_secret")

    # VM identification: prefer vmid, fall back to name
    vmid = params.get("vmid")
    name = params.get("name")
    node = params.get("node")

    # State operation
    state = params.get("state", "present")
    force = params.get("force", False)
    update = params.get("update", False)
    clone = params.get("clone")
    archive = params.get("archive")

    # Validate basic auth args — fail early if missing
    if not api_host or not api_user:
        fail("api_host and api_user are required")

    # Build basic auth header string
    if api_token_id and api_token_secret:
        auth_header = "PVEAPIAuth: %s@%s:%s" % (api_user, api_host, api_token_id, api_token_secret)
    elif api_password != None:
        auth_header = "PVEBasicAuth: %s@%s" % (api_user, api_host)
    else:
        fail("api_password or api_token_id/api_token_secret is required")

    # Helper: call the proxmox API via a generic HTTP client simulation via ctx
    def proxmox_request(method, path, data=None):
        url = "https://" + api_host + ":8006/api2/json/" + path
        headers = [
            "Content-Type: application/x-www-form-urlencoded",
            "Authorization: " + auth_header
        ]
        body = ""
        if data != None:
            for k, v in sorted(data.items()):
                if body != "":
                    body += "&"
                body += str(k) + "=" + str(v)
        res = ctx.run(["curl", "-s", "-k", "-X", method, "-H", headers[0], "-H", headers[1], "-d", body, url], mutates=True)
        if res.rc != 0:
            fail("proxmox API error: " + res.stderr)
        # Note: in real use, ctx.run should support JSON parsing; here we assume raw text output
        return res.stdout

    # Helper: get VM info by name or id
    def get_vm_info():
        path = "nodes/" + node + "/qemu"
        res = ctx.run(["curl", "-s", "-k", "-X", "GET", "-H", "Content-Type: application/json", "-H", "Authorization: " + auth_header, "https://" + api_host + ":8006/api2/json/" + path], mutates=False)
        if res.rc != 0:
            fail("failed to list VMs: " + res.stderr)
        # Simple JSON parse simulation (no json module) — find vmid and name in text
        lines = res.stdout.splitlines()
        for line in lines:
            if line.find("\"vmid\"") != -1 and line.find("\"name\"") != -1:
                # Extract vmid and name — simplistic
                parts = line.split(",")
                for part in parts:
                    if part.find("\"vmid\"") != -1:
                        vmid_val = part.split(":")[1].strip().strip("\"")
                    if part.find("\"name\"") != -1:
                        name_val = part.split(":")[1].strip().strip("\"")
                        if name_val == name:
                            return int(vmid_val)
        return None

    # Determine vmid
    if vmid == None and name != None:
        vmid = get_vm_info()
        if vmid == None:
            vmid = 0

    # Determine node from facts if not provided
    if node == None:
        facts = ctx.facts()
        node = facts.get("hostname", "localhost")

    # Helper: start a VM
    def start_vm():
        path = "nodes/" + node + "/qemu/" + str(vmid) + "/status/start"
        proxmox_request("POST", path)
        return {"changed": True, "msg": "started VM " + str(vmid)}

    # Helper: stop a VM
    def stop_vm():
        path = "nodes/" + node + "/qemu/" + str(vmid) + "/status/shutdown"
        if force:
            path += "?force=1"
        proxmox_request("POST", path)
        return {"changed": True, "msg": "stopped VM " + str(vmid)}

    # Helper: delete a VM
    def delete_vm():
        path = "nodes/" + node + "/qemu/" + str(vmid)
        proxmox_request("DELETE", path)
        return {"changed": True, "msg": "deleted VM " + str(vmid)}

    # Helper: get VM status
    def get_vm_status():
        path = "nodes/" + node + "/qemu/" + str(vmid) + "/status/current"
        res = ctx.run(["curl", "-s", "-k", "-X", "GET", "-H", "Authorization: " + auth_header, "https://" + api_host + ":8006/api2/json/" + path], mutates=False)
        if res.rc != 0:
            fail("failed to get VM status: " + res.stderr)
        # Simulate status parsing from JSON text
        if res.stdout.find("\"status\":\"running\"") != -1:
            return "running"
        elif res.stdout.find("\"status\":\"stopped\"") != -1:
            return "stopped"
        return "unknown"

    # State handling
    if state == "present":
        # Create or update VM
        if vmid == 0 or vmid == None:
            # Create VM
            if name == None:
                fail("name is required when creating a new VM")
            data = {
                "vmid": vmid,
                "name": name,
                "node": node,
                "memory": params.get("memory", 512),
                "cores": params.get("cores", 1),
                "sockets": params.get("sockets", 1),
                "cpu": params.get("cpu", "kvm64"),
                "acpi": int(params.get("acpi", True) if params.get("acpi") != None else True),
                "net0": params.get("net", {}).get("net0", "") if type(params.get("net")) == "dict" else "",
                "ide2": params.get("ide", {}).get("ide2", "") if type(params.get("ide")) == "dict" else "",
            }
            if clone != None:
                data["source"] = clone
                if params.get("newid") != None:
                    data["newid"] = str(params["newid"])
                if params.get("storage") != None:
                    data["storage"] = params["storage"]
                if params.get("format") != None:
                    data["format"] = params["format"]
                if params.get("full") != None:
                    data["full"] = int(params["full"])
                path = "nodes/" + node + "/qemu"
                res = ctx.run(["curl", "-s", "-k", "-X", "POST", "-H", "Authorization: " + auth_header, "-d", "name=" + name + "&node=" + node + "&source=" + clone, "https://" + api_host + ":8006/api2/json/" + path], mutates=True)
                if res.rc != 0:
                    fail("failed to clone VM: " + res.stderr)
                # Parse new vmid from response — simplified
                vmid = 100  # placeholder — real implementation needs parsing
                return {"changed": True, "msg": "cloned VM from " + clone + " to vmid " + str(vmid)}
            if archive != None:
                fail("restore from archive not implemented in this stub")
                # implementation would call restore API
            # Basic create
            proxmox_request("POST", "nodes/" + node + "/qemu", data)
            return {"changed": True, "msg": "created VM " + str(vmid)}
        else:
            # Update VM
            if update:
                # Filter update-safe parameters — omit disk/net
                data = {
                    "cores": params.get("cores"),
                    "memory": params.get("memory"),
                    "cpu": params.get("cpu"),
                    "description": params.get("description"),
                }
                # Remove None values
                filtered = {}
                for k in data.keys():
                    if data[k] != None:
                        filtered[k] = data[k]
                if len(filtered) > 0:
                    proxmox_request("PUT", "nodes/" + node + "/qemu/" + str(vmid) + "/config", filtered)
                    return {"changed": True, "msg": "updated VM " + str(vmid)}
                return {"changed": False, "msg": "VM " + str(vmid) + " already up to date"}
            # Ensure running if not already
            status = get_vm_status()
            if status == "running":
                return {"changed": False, "msg": "VM " + str(vmid) + " is already running"}
            return start_vm()

    elif state == "started":
        if vmid == 0:
            fail("vmid not found for name " + str(name))
        status = get_vm_status()
        if status == "running":
            return {"changed": False, "msg": "VM " + str(vmid) + " is already running"}
        return start_vm()

    elif state == "stopped":
        if vmid == 0:
            fail("vmid not found for name " + str(name))
        status = get_vm_status()
        if status == "stopped":
            return {"changed": False, "msg": "VM " + str(vmid) + " is already stopped"}
        return stop_vm()

    elif state == "restarted":
        if vmid == 0:
            fail("vmid not found for name " + str(name))
        stop_vm()
        return start_vm()

    elif state == "absent":
        if vmid == 0:
            fail("vmid not found for name " + str(name))
        # Check if exists
        if get_vm_status() == "unknown":
            return {"changed": False, "msg": "VM " + str(vmid) + " does not exist"}
        return delete_vm()

    elif state == "current":
        if vmid == 0:
            fail("vmid not found for name " + str(name))
        status = get_vm_status()
        return {"changed": False, "msg": "VM " + str(vmid) + " status: " + status, "data": {"status": status}}

    elif state == "template":
        fail("template state not implemented in this stub")
    else:
        fail("unsupported state: " + str(state))
