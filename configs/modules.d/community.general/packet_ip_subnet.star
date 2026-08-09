def main(ctx, params):
    auth_token = params.get("auth_token")
    cidr = params["cidr"]
    device_count = params.get("device_count", 100)
    device_id = params.get("device_id")
    hostname = params.get("hostname")
    project_id = params["project_id"]
    state = params.get("state", "present")

    # Validate required params
    if auth_token == None:
        fail("auth_token is required (or set PACKET_API_TOKEN environment variable)")
    if device_id == None and hostname == None and state == "present":
        fail("With state=present, you must specify either hostname or device_id")

    # Parse CIDR (address/prefixlen)
    if cidr.find("/") == -1:
        fail("CIDR expression must be in format address/prefix_len")
    slash_idx = cidr.rfind("/")
    address = cidr[:slash_idx]
    prefixlen_str = cidr[slash_idx+1:]
    if prefixlen_str.isdigit() == False:
        fail("Invalid prefix length in CIDR: " + cidr)
    prefixlen = int(prefixlen_str)

    # Get devices list (read-only)
    res = ctx.run(["curl", "-sS", "-X", "GET",
                   "-H", "X-Auth-Token: " + auth_token,
                   "-H", "Accept: application/json",
                   "https://api.packet.net/projects/" + project_id + "/devices?per_page=" + str(device_count)])
    if res.rc != 0:
        fail("Failed to list devices: " + res.stderr)

    # Parse devices list
    devices_raw = res.stdout
    # Manual JSON parsing: find device arrays between '[{' and '}]'
    # We look for "id" and "hostname" fields using simple string search
    devices = []
    # Remove outer brackets and split entries
    if devices_raw.strip().startswith("[") and devices_raw.strip().endswith("]"):
        devices_raw = devices_raw.strip()[1:-1]  # Remove outer [ ]
        if devices_raw == "":
            devices = []
        else:
            # Split by },{ pattern (basic heuristic)
            parts = devices_raw.split("},{")
            for part in parts:
                if part.strip() == "":
                    continue
                # Ensure proper wrapping for parsing
                entry = part.strip()
                if not entry.startswith("{"):
                    entry = "{" + entry
                if not entry.endswith("}"):
                    entry = entry + "}"
                # Extract id and hostname
                device_id_found = ""
                hostname_found = ""
                # Look for id field
                id_pos = entry.find('"id"')
                if id_pos != -1:
                    start = entry.find('"', id_pos+3)
                    end = entry.find('"', start+1)
                    if start != -1 and end != -1:
                        device_id_found = entry[start+1:end]
                # Look for hostname field
                hn_pos = entry.find('"hostname"')
                if hn_pos != -1:
                    start = entry.find('"', hn_pos+11)
                    end = entry.find('"', start+1)
                    if start != -1 and end != -1:
                        hostname_found = entry[start+1:end]
                if device_id_found != "":
                    devices.append({"id": device_id_found, "hostname": hostname_found})
    else:
        fail("Unexpected device list format")

    # Resolve target device
    target_device = None
    if device_id != None:
        for d in devices:
            if d["id"] == device_id:
                target_device = d
                break
        if target_device == None:
            fail("Device with id " + device_id + " not found")
    elif hostname != None:
        matching = [d for d in devices if d["hostname"] == hostname]
        if len(matching) == 0:
            fail("No device found with hostname " + hostname)
        if len(matching) > 1:
            fail("Multiple devices found with hostname " + hostname)
        target_device = matching[0]

    # In check_mode, predict change without mutation
    if ctx.check_mode:
        if state == "present":
            if target_device == None:
                return {"changed": False, "msg": "device not found (check_mode)", "changed": False}
            # Check if subnet already assigned to target device
            res_ips = ctx.run(["curl", "-sS", "-X", "GET",
                               "-H", "X-Auth-Token: " + auth_token,
                               "-H", "Accept: application/json",
                               "https://api.packet.net/devices/" + target_device["id"] + "/ips"])
            if res_ips.rc != 0:
                # If IP list fails, assume not assigned (safe for check_mode)
                return {"changed": True, "msg": "would assign subnet to device " + target_device["id"]}
            ips_raw = res_ips.stdout
            assigned = False
            # Check if address/prefixlen already in ips list (very basic check)
            if address in ips_raw and str(prefixlen) in ips_raw:
                # Further validation: ensure it's the same subnet
                # We'll use string search for "address": "1.2.3.4" and "cidr": 32 pattern
                # This is simplified; in practice, we'd parse better
                if '"address": "' + address + '"' in ips_raw and '"cidr": ' + str(prefixlen) in ips_raw:
                    assigned = True
            return {"changed": not assigned, "msg": ("already assigned" if assigned else "would assign subnet")}
        else:  # absent
            if target_device != None:
                res_ips = ctx.run(["curl", "-sS", "-X", "GET",
                                   "-H", "X-Auth-Token: " + auth_token,
                                   "-H", "Accept: application/json",
                                   "https://api.packet.net/devices/" + target_device["id"] + "/ips"])
                if res_ips.rc != 0:
                    return {"changed": False, "msg": "could not check assignments"}
                ips_raw = res_ips.stdout
                assigned = False
                if '"address": "' + address + '"' in ips_raw and '"cidr": ' + str(prefixlen) in ips_raw:
                    assigned = True
                return {"changed": assigned, "msg": ("already removed" if not assigned else "would remove subnet")}
            else:
                # No device specified: check if subnet is assigned anywhere
                for d in devices:
                    res_ips = ctx.run(["curl", "-sS", "-X", "GET",
                                       "-H", "X-Auth-Token: " + auth_token,
                                       "-H", "Accept: application/json",
                                       "https://api.packet.net/devices/" + d["id"] + "/ips"])
                    if res_ips.rc == 0:
                        if address in res_ips.stdout and str(prefixlen) in res_ips.stdout:
                            return {"changed": True, "msg": "would remove subnet from device " + d["id"]}
                return {"changed": False, "msg": "subnet not assigned anywhere"}

    # Actual execution (non check_mode)
    changed = False
    subnet_data = None

    if state == "present":
        if target_device == None:
            fail("Device not found")
        # Check if already assigned
        res_ips = ctx.run(["curl", "-sS", "-X", "GET",
                           "-H", "X-Auth-Token: " + auth_token,
                           "-H", "Accept: application/json",
                           "https://api.packet.net/devices/" + target_device["id"] + "/ips"])
        if res_ips.rc != 0:
            fail("Failed to list IPs for device " + target_device["id"] + ": " + res.stderr)
        ips_raw = res_ips.stdout
        assigned = False
        if '"address": "' + address + '"' in ips_raw and '"cidr": ' + str(prefixlen) in ips_raw:
            assigned = True
        if assigned:
            return {"changed": False, "msg": "subnet already assigned to device " + target_device["id"]}

        # Assign subnet
        body = '{"address": "' + cidr + '"}'
        res_assign = ctx.run(["curl", "-sS", "-X", "POST",
                              "-H", "X-Auth-Token: " + auth_token,
                              "-H", "Accept: application/json",
                              "-H", "Content-Type: application/json",
                              "-d", body,
                              "https://api.packet.net/devices/" + target_device["id"] + "/ips"])
        if res_assign.rc != 0:
            fail("Failed to assign subnet: " + res_assign.stderr)
        # Parse response for subnet data (simplified)
        subnet_data_raw = res_assign.stdout
        # Extract id for return
        id_pos = subnet_data_raw.find('"id"')
        subnet_id = ""
        if id_pos != -1:
            start = subnet_data_raw.find('"', id_pos+3)
            end = subnet_data_raw.find('"', start+1)
            if start != -1 and end != -1:
                subnet_id = subnet_data_raw[start+1:end]
        subnet_data = {"id": subnet_id, "address": address, "cidr": prefixlen}
        changed = True
        return {"changed": changed, "msg": "assigned subnet " + cidr + " to device " + target_device["id"],
                "device_id": target_device["id"], "subnet": subnet_data}

    elif state == "absent":
        if target_device != None:
            # Remove from specific device
            res_ips = ctx.run(["curl", "-sS", "-X", "GET",
                               "-H", "X-Auth-Token: " + auth_token,
                               "-H", "Accept: application/json",
                               "https://api.packet.net/devices/" + target_device["id"] + "/ips"])
            if res_ips.rc != 0:
                fail("Failed to list IPs for device " + target_device["id"] + ": " + res.stderr)
            ips_raw = res_ips.stdout
            # Find assignment href (simplified)
            # Look for the assignment with matching address and cidr and extract href
            href = ""
            # Basic search: find "href" value in same JSON object as address + cidr
            if '"address": "' + address + '"' in ips_raw and '"cidr": ' + str(prefixlen) in ips_raw:
                # Extract full assignment object and find href
                start_obj = ips_raw.find('{"address": "' + address + '"')
                if start_obj == -1:
                    start_obj = ips_raw.find('"address": "' + address + '"')
                if start_obj != -1:
                    # Find the closing brace
                    brace_count = 0
                    i = start_obj
                    while i < len(ips_raw) and brace_count >= 0:
                        if ips_raw[i] == '{':
                            brace_count += 1
                        elif ips_raw[i] == '}':
                            brace_count -= 1
                        i += 1
                    obj_end = i
                    assignment_obj = ips_raw[start_obj:obj_end]
                    # Extract href from assignment_obj
                    href_pos = assignment_obj.find('"href"')
                    if href_pos != -1:
                        start = assignment_obj.find('"', href_pos+5)
                        end = assignment_obj.find('"', start+1)
                        if start != -1 and end != -1:
                            href = assignment_obj[start+1:end]
            if href == "":
                # Not found; return no change
                return {"changed": False, "msg": "subnet not assigned to device " + target_device["id"]}
            res_delete = ctx.run(["curl", "-sS", "-X", "DELETE",
                                  "-H", "X-Auth-Token: " + auth_token,
                                  "https://api.packet.net" + href])
            if res_delete.rc != 0:
                fail("Failed to delete IP assignment: " + res_delete.stderr)
            changed = True
            return {"changed": changed, "msg": "removed subnet " + cidr + " from device " + target_device["id"],
                    "device_id": target_device["id"]}

        else:
            # Remove from any device (scan all devices)
            found = False
            for d in devices:
                res_ips = ctx.run(["curl", "-sS", "-X", "GET",
                                   "-H", "X-Auth-Token: " + auth_token,
                                   "-H", "Accept: application/json",
                                   "https://api.packet.net/devices/" + d["id"] + "/ips"])
                if res_ips.rc != 0:
                    continue
                ips_raw = res_ips.stdout
                if '"address": "' + address + '"' in ips_raw and '"cidr": ' + str(prefixlen) in ips_raw:
                    # Extract href
                    href = ""
                    start_obj = ips_raw.find('{"address": "' + address + '"')
                    if start_obj == -1:
                        start_obj = ips_raw.find('"address": "' + address + '"')
                    if start_obj != -1:
                        brace_count = 0
                        i = start_obj
                        while i < len(ips_raw) and brace_count >= 0:
                            if ips_raw[i] == '{':
                                brace_count += 1
                            elif ips_raw[i] == '}':
                                brace_count -= 1
                            i += 1
                        obj_end = i
                        assignment_obj = ips_raw[start_obj:obj_end]
                        href_pos = assignment_obj.find('"href"')
                        if href_pos != -1:
                            start = assignment_obj.find('"', href_pos+5)
                            end = assignment_obj.find('"', start+1)
                            if start != -1 and end != -1:
                                href = assignment_obj[start+1:end]
                    if href != "":
                        res_delete = ctx.run(["curl", "-sS", "-X", "DELETE",
                                              "-H", "X-Auth-Token: " + auth_token,
                                              "https://api.packet.net" + href])
                        if res_delete.rc != 0:
                            fail("Failed to delete IP assignment for " + address + "/" + str(prefixlen))
                        found = True
                        changed = True
                        # Continue to remove from other devices? Original code stops at first match.
                        # For compatibility, stop after first removal as per original logic.
                        return {"changed": changed, "msg": "removed subnet " + cidr + " from device " + d["id"],
                                "device_id": d["id"]}
            if not found:
                return {"changed": False, "msg": "subnet not assigned to any device"}
