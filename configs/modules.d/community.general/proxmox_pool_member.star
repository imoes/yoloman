def main(ctx, params):
    api_host = params["api_host"]
    api_user = params["api_user"]
    api_password = params.get("api_password")
    api_token_id = params.get("api_token_id")
    api_token_secret = params.get("api_token_secret")
    poolid = params["poolid"]
    member = params["member"]
    member_type = params.get("type", "vm")
    state = params.get("state", "present")
    validate_certs = params.get("validate_certs", False)

    # Build curl command for Proxmox API calls
    def build_curl_cmd(path, method="GET", data=None):
        cmd = ["curl", "-s", "-k"]
        if not validate_certs:
            cmd.append("-k")
        cmd.extend([
            "-X", method,
            "-H", "Content-Type: application/x-www-form-urlencoded"
        ])
        if api_token_id:
            cmd.extend(["-H", "Authorization: PVEAPIToken={0}={1}".format(api_token_id, api_token_secret)])
        else:
            fail("Authentication with username/password not fully supported in Starlark translation. Please use api_token_id/api_token_secret.")

        cmd.append("https://%s:8006/api2/json%s" % (api_host, path))
        if data:
            cmd.extend(["-d", data])
        return cmd

    # Helper: parse minimal JSON response (basic support for known keys)
    def parse_json_key(data, key):
        # Look for "key": "value" or "key": number patterns
        start = data.find('"' + key + '"')
        if start == -1:
            return None
        start = data.find(":", start)
        if start == -1:
            return None
        start += 1
        # Skip whitespace
        while start < len(data) and (data[start] == " " or data[start] == "\t" or data[start] == "\n"):
            start += 1
        if start >= len(data):
            return None
        if data[start] == '"':
            start += 1
            end = start
            while end < len(data) and data[end] != '"':
                if data[end] == '\\' and end + 1 < len(data):
                    end += 2
                else:
                    end += 1
            return data[start:end]
        else:
            # numeric
            end = start
            while end < len(data) and (data[end].isdigit() or data[end] == '-' or data[end] == '+'):
                end += 1
            return data[start:end]

    # Helper: get pool info
    def get_pool_members(poolid):
        res = ctx.run(build_curl_cmd("/pools/" + poolid), mutates=False)
        if res.rc != 0:
            fail("Failed to get pool %s: %s" % (poolid, res.stderr))
        members = []
        # Parse data.members array manually
        data_section = parse_json_key(res.stdout, "data")
        if data_section == None:
            fail("Failed to parse pool data")
        # Look for members
        members_start = data_section.find('"members"')
        if members_start == -1:
            return [], []
        members_start = data_section.find("[", members_start)
        if members_start == -1:
            return [], []
        # Find closing bracket
        depth = 0
        members_str = ""
        for i in range(members_start, len(data_section)):
            c = data_section[i]
            if c == '[':
                depth += 1
            elif c == ']':
                depth -= 1
            members_str += c
            if depth == 0:
                break

        vms = []
        storage = []
        # Split by '{...}' entries
        entries = members_str.split("{")
        for entry in entries:
            if "vmid" in entry:
                vmid = parse_json_key(entry, "vmid")
                if vmid != None:
                    vms.append(str(vmid))
            elif "storage" in entry:
                st = parse_json_key(entry, "storage")
                if st != None:
                    storage.append(str(st))
        return vms, storage

    # Helper: get storages list
    def get_storages():
        res = ctx.run(build_curl_cmd("/storage"), mutates=False)
        if res.rc != 0:
            fail("Failed to list storages: %s" % res.stderr)
        storages = []
        data_section = parse_json_key(res.stdout, "data")
        if data_section == None:
            return storages
        # Extract each storage name
        # Simplified: find all "storage": "..." entries
        pos = 0
        while True:
            idx = data_section.find('"storage"', pos)
            if idx == -1:
                break
            # Find next string value after colon
            start = data_section.find('"', idx)
            if start == -1:
                break
            end = data_section.find('"', start + 1)
            if end == -1:
                break
            storages.append(data_section[start + 1:end])
            pos = end + 1
        return storages

    # Helper: get vmid from vm name
    def get_vmid(vmname):
        res = ctx.run(build_curl_cmd("/cluster/resources?type=vm"), mutates=False)
        if res.rc != 0:
            fail("Failed to list VMs: %s" % res.stderr)
        data_section = parse_json_key(res.stdout, "data")
        if data_section == None:
            fail("Failed to parse VM list")
        # Look for "name": vmname and extract vmid
        # Find all occurrences of name and vmid pairs
        idx = 0
        while idx < len(data_section):
            name_idx = data_section.find('"name"', idx)
            if name_idx == -1:
                break
            # Get name value
            start = data_section.find('"', name_idx)
            if start == -1:
                break
            end = data_section.find('"', start + 1)
            if end == -1:
                break
            name_val = data_section[start + 1:end]
            if name_val == vmname:
                # Now find vmid in the same object (assume it's earlier in the JSON)
                obj_start = data_section.rfind('{', 0, name_idx)
                if obj_start == -1:
                    obj_start = 0
                vmid_str = parse_json_key(data_section[obj_start:name_idx + 50], "vmid")
                if vmid_str != None:
                    return str(vmid_str)
            idx = end + 1
        return None

    if state not in ["present", "absent"]:
        fail("Invalid state: must be 'present' or 'absent'")

    vms, storage = get_pool_members(poolid)

    if state == "present":
        diff_before = list(storage) + list(vms)
        diff_after = list(diff_before)

        if member_type == "storage":
            storages = get_storages()
            if member not in storages:
                fail("Storage %s doesn't exist in the cluster" % member)
            if member in storage:
                return {
                    "changed": False,
                    "msg": "Member %s is already part of the pool %s" % (member, poolid),
                    "data": {"poolid": poolid, "member": member}
                }
            diff_after.append(member)
        else:
            # Check if member is numeric directly
            is_numeric = True
            for c in member:
                if not (c.isdigit()):
                    is_numeric = False
                    break
            if is_numeric:
                vmid = str(member)
            else:
                vmid = get_vmid(member)
                if vmid == None:
                    fail("VM %s not found" % member)

            if vmid in vms:
                return {
                    "changed": False,
                    "msg": "VM %s is already part of the pool %s" % (member, poolid),
                    "data": {"poolid": poolid, "member": member}
                }
            diff_after.append(member)

        if ctx.check_mode:
            return {
                "changed": True,
                "msg": "would add member %s to pool %s" % (member, poolid),
                "diff": {"before": {"members": diff_before}, "after": {"members": diff_after}},
                "data": {"poolid": poolid, "member": member}
            }

        # Perform the API call
        if member_type == "storage":
            cmd_data = "storage=" + member
        else:
            cmd_data = "vms=" + vmid
        cmd = build_curl_cmd("/pools/" + poolid, method="PUT", data=cmd_data)
        res = ctx.run(cmd, mutates=True)
        if res.rc != 0:
            fail("Failed to add member %s to pool %s: %s" % (member, poolid, res.stderr))

        return {
            "changed": True,
            "msg": "New member %s added to the pool %s" % (member, poolid),
            "diff": {"before": {"members": diff_before}, "after": {"members": diff_after}},
            "data": {"poolid": poolid, "member": member}
        }

    else:  # absent
        diff_before = list(storage) + list(vms)
        diff_after = list(diff_before)

        if member_type == "storage":
            if member not in storage:
                return {
                    "changed": False,
                    "msg": "Member %s is not part of the pool %s" % (member, poolid),
                    "data": {"poolid": poolid, "member": member}
                }
            diff_after.remove(member)
        else:
            # Check if member is numeric directly
            is_numeric = True
            for c in member:
                if not (c.isdigit()):
                    is_numeric = False
                    break
            if is_numeric:
                vmid = str(member)
            else:
                vmid = get_vmid(member)
                if vmid == None:
                    fail("VM %s not found" % member)

            if vmid not in vms:
                return {
                    "changed": False,
                    "msg": "VM %s is not part of the pool %s" % (member, poolid),
                    "data": {"poolid": poolid, "member": member}
                }
            diff_after.remove(vmid)

        if ctx.check_mode:
            return {
                "changed": True,
                "msg": "would remove member %s from pool %s" % (member, poolid),
                "diff": {"before": {"members": diff_before}, "after": {"members": diff_after}},
                "data": {"poolid": poolid, "member": member}
            }

        # Perform deletion
        if member_type == "storage":
            cmd_data = "storage=" + member + "&delete=1"
        else:
            cmd_data = "vms=" + vmid + "&delete=1"
        cmd = build_curl_cmd("/pools/" + poolid, method="PUT", data=cmd_data)
        res = ctx.run(cmd, mutates=True)
        if res.rc != 0:
            fail("Failed to delete member %s from pool %s: %s" % (member, poolid, res.stderr))

        return {
            "changed": True,
            "msg": "Member %s deleted from the pool %s" % (member, poolid),
            "diff": {"before": {"members": diff_before}, "after": {"members": diff_after}},
            "data": {"poolid": poolid, "member": member}
        }
