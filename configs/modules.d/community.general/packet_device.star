def main(ctx, params):
    auth_token = params.get("auth_token")
    if auth_token == None:
        fail("auth_token is required (or set PACKET_API_TOKEN environment variable)")

    project_id = params["project_id"]
    state = params.get("state", "present")
    device_ids = params.get("device_ids")
    hostnames = params.get("hostnames")
    count = params.get("count", 1)
    count_offset = params.get("count_offset", 1)
    wait_timeout = params.get("wait_timeout", 900)
    wait_for_ipv = params.get("wait_for_public_IPv")
    locked = params.get("locked", False)
    plan = params.get("plan")
    operating_system = params.get("operating_system")
    facility = params.get("facility")
    tags = params.get("tags")
    user_data = params.get("user_data")
    ipxe_script_url = params.get("ipxe_script_url", "")
    always_pxe = params.get("always_pxe", False)
    features = params.get("features", {})

    if device_ids != None and hostnames != None:
        fail("device_ids and hostnames are mutually exclusive")

    if isinstance(device_ids, str):
        device_ids = [d.strip() for d in device_ids.split(",")]
    elif device_ids == None:
        device_ids = []
    else:
        device_ids = [str(d).strip() for d in device_ids]

    # Validate device IDs
    for di in device_ids:
        if len(di) != 36 or di.count("-") != 4:
            fail("Invalid device ID format: %s" % di)

    # Expand hostnames
    hostname_list = []
    if hostnames == None:
        hostname_list = []
    elif isinstance(hostnames, str):
        hostname_list = [hostnames.strip()]
    else:
        hostname_list = [str(h).strip() for h in hostnames]

    if len(hostname_list) > 1 and count > 1:
        fail("If you set count>1, you should only specify one hostname with the %d formatter, not a list of hostnames.")

    if len(hostname_list) == 1 and count > 0:
        hostname_spec = hostname_list[0]
        count_range = range(count_offset, count_offset + count)
        if "%d" in hostname_spec or "%02d" in hostname_spec or "%03d" in hostname_spec:
            hostname_list = [hostname_spec % i for i in count_range]
        elif count > 1:
            hostname_list = [("%s%%02d" % hostname_spec) % i for i in count_range]

    if state == "absent":
        # Delete devices by ID
        changed = False
        for di in device_ids:
            res = ctx.run([
                "curl", "-s", "-X", "DELETE",
                "-H", "X-Auth-Token: " + auth_token,
                "-H", "Accept: application/json",
                "https://api.packet.net/v1/devices/" + di
            ], mutates=True)
            if res.rc != 0:
                fail("Failed to delete device %s: %s" % (di, res.stderr))
            changed = True

        return {"changed": changed, "msg": "Deleted devices: " + str(device_ids), "devices": []}

    # List existing devices
    res = ctx.run([
        "curl", "-s",
        "-H", "X-Auth-Token: " + auth_token,
        "-H", "Accept: application/json",
        "https://api.packet.net/v1/projects/" + project_id + "/devices?per_page=100"
    ])
    if res.rc != 0:
        fail("Failed to list devices: " + res.stderr)

    # Parse devices list
    devices_raw = res.stdout
    # Simple JSON parsing without json module - find device objects
    # Format: { "devices": [ { ... }, ... ] }
    devices = []
    start_idx = devices_raw.find('"devices"')
    if start_idx != -1:
        start_brace = devices_raw.find('[', start_idx)
        if start_brace != -1:
            end_brace = start_brace + 1
            depth = 1
            while end_brace < len(devices_raw) and depth > 0:
                if devices_raw[end_brace] == '[':
                    depth += 1
                elif devices_raw[end_brace] == ']':
                    depth -= 1
                end_brace += 1
            devices_str = devices_raw[start_brace:end_brace]
            # Parse device entries
            entries = devices_str.split("{")
            for i in range(1, len(entries)):
                entry = "{" + entries[i].rstrip().rstrip(",") + "}"
                if "id" in entry:
                    dev = {}
                    # Extract id
                    id_start = entry.find('"id"')
                    if id_start != -1:
                        id_colon = entry.find(":", id_start)
                        id_quote = entry.find('"', id_colon)
                        id_end = entry.find('"', id_quote + 1)
                        dev["id"] = entry[id_quote + 1:id_end]
                    # Extract hostname
                    hn_start = entry.find('"hostname"')
                    if hn_start != -1:
                        hn_colon = entry.find(":", hn_start)
                        hn_quote = entry.find('"', hn_colon)
                        hn_end = entry.find('"', hn_quote + 1)
                        dev["hostname"] = entry[hn_quote + 1:hn_end]
                    # Extract state
                    st_start = entry.find('"state"')
                    if st_start != -1:
                        st_colon = entry.find(":", st_start)
                        st_quote = entry.find('"', st_colon)
                        st_end = entry.find('"', st_quote + 1)
                        dev["state"] = entry[st_quote + 1:st_end]
                    # Extract locked
                    lk_start = entry.find('"locked"')
                    if lk_start != -1:
                        lk_colon = entry.find(":", lk_start)
                        lk_val = entry[lk_colon + 1:lk_colon + 6].strip()
                        dev["locked"] = lk_val.startswith("true")
                    # Extract ip_addresses
                    ip_start = entry.find('"ip_addresses"')
                    if ip_start != -1:
                        ip_colon = entry.find(":", ip_start)
                        ip_brace = entry.find("[", ip_colon)
                        ip_end = ip_brace + 1
                        depth = 1
                        while ip_end < len(entry) and depth > 0:
                            if entry[ip_end] == '[':
                                depth += 1
                            elif entry[ip_end] == ']':
                                depth -= 1
                            ip_end += 1
                        ip_list_str = entry[ip_brace:ip_end]
                        # Parse IPs
                        public_v4 = ""
                        public_v6 = ""
                        private_v4 = ""
                        private_v6 = ""
                        # Split by objects
                        ip_entries = ip_list_str.split("{")
                        for j in range(1, len(ip_entries)):
                            ip_entry = "{" + ip_entries[j].rstrip().rstrip(",") + "}"
                            # address
                            addr_start = ip_entry.find('"address"')
                            if addr_start != -1:
                                addr_colon = ip_entry.find(":", addr_start)
                                addr_quote = ip_entry.find('"', addr_colon)
                                addr_end = ip_entry.find('"', addr_quote + 1)
                                addr = ip_entry[addr_quote + 1:addr_end]
                            # address_family
                            af_start = ip_entry.find('"address_family"')
                            if af_start != -1:
                                af_colon = ip_entry.find(":", af_start)
                                af_end = ip_entry.find(",", af_colon)
                                if af_end == -1:
                                    af_end = ip_entry.find("}", af_colon)
                                af_val = ip_entry[af_colon + 1:af_end].strip()
                                af = int(af_val)
                            # public
                            pub_start = ip_entry.find('"public"')
                            if pub_start != -1:
                                pub_colon = ip_entry.find(":", pub_start)
                                pub_val = ip_entry[pub_colon + 1:pub_colon + 6].strip()
                                pub = pub_val.startswith("true")

                            if pub and af == 4:
                                public_v4 = addr
                            elif pub and af == 6:
                                public_v6 = addr
                            elif not pub and af == 4:
                                private_v4 = addr
                            elif not pub and af == 6:
                                private_v6 = addr

                        dev["public_ipv4"] = public_v4
                        dev["public_ipv6"] = public_v6
                        dev["private_ipv4"] = private_v4
                        dev["private_ipv6"] = private_v6
                    devices.append(dev)

    # Filter to specified devices
    target_devices = []
    hostnames_to_create = []

    if len(device_ids) > 0:
        # Match by ID
        for di in device_ids:
            found = False
            for d in devices:
                if d.get("id") == di:
                    target_devices.append(d)
                    found = True
                    break
            if not found:
                # This device doesn't exist - will be skipped (can't create with IDs)
                fail("Device %s does not exist and cannot be created by ID" % di)
    else:
        # Match by hostname
        existing_hostnames = [d.get("hostname", "") for d in devices]
        for hn in hostname_list:
            found = False
            for d in devices:
                if d.get("hostname") == hn:
                    target_devices.append(d)
                    found = True
                    break
            if not found:
                if state in ["present", "active", "rebooted"]:
                    hostnames_to_create.append(hn)

    # Handle non-create states for existing devices
    if state == "active":
        for d in target_devices:
            if d["state"] != "active":
                res = ctx.run([
                    "curl", "-s", "-X", "POST",
                    "-H", "X-Auth-Token: " + auth_token,
                    "-H", "Content-Type: application/json",
                    "https://api.packet.net/v1/devices/" + d["id"] + "/actions",
                    "-d", '{"type":"power_on"}'
                ], mutates=True)
                if res.rc != 0:
                    fail("Failed to power on device %s: %s" % (d["id"], res.stderr))
    elif state == "inactive":
        for d in target_devices:
            if d["state"] != "inactive":
                res = ctx.run([
                    "curl", "-s", "-X", "POST",
                    "-H", "X-Auth-Token: " + auth_token,
                    "-H", "Content-Type: application/json",
                    "https://api.packet.net/v1/devices/" + d["id"] + "/actions",
                    "-d", '{"type":"power_off"}'
                ], mutates=True)
                if res.rc != 0:
                    fail("Failed to power off device %s: %s" % (d["id"], res.stderr))
    elif state == "rebooted":
        for d in target_devices:
            res = ctx.run([
                "curl", "-s", "-X", "POST",
                "-H", "X-Auth-Token: " + auth_token,
                "-H", "Content-Type: application/json",
                "https://api.packet.net/v1/devices/" + d["id"] + "/actions",
                "-d", '{"type":"reboot"}'
            ], mutates=True)
            if res.rc != 0:
                fail("Failed to reboot device %s: %s" % (d["id"], res.stderr))

    # Create new devices
    created_devices = []
    if len(hostnames_to_create) > 0:
        for hn in hostnames_to_create:
            # Build payload
            payload_parts = [
                '"hostname":"%s"' % hn,
                '"plan":"%s"' % plan,
                '"operating_system":"%s"' % operating_system,
                '"project_id":"%s"' % project_id
            ]
            if facility != None:
                payload_parts.append('"facility":"%s"' % facility)
            if locked:
                payload_parts.append('"locked":true')
            if tags != None:
                payload_parts.append('"tags":[' + ",".join(['"%s"' % t for t in tags]) + ']')
            if user_data != None:
                payload_parts.append('"userdata":"%s"' % user_data.replace("\\", "\\\\").replace('"', '\\"'))
            if ipxe_script_url != "":
                payload_parts.append('"ipxe_script_url":"%s"' % ipxe_script_url)
                payload_parts.append('"always_pxe":true')
            elif always_pxe:
                fail("always_pxe is only valid with custom_ipxe operating_system")

            payload = "{" + ",".join(payload_parts) + "}"

            res = ctx.run([
                "curl", "-s", "-X", "POST",
                "-H", "X-Auth-Token: " + auth_token,
                "-H", "Content-Type: application/json",
                "https://api.packet.net/v1/projects/" + project_id + "/devices",
                "-d", payload
            ], mutates=True)

            if res.rc != 0:
                fail("Failed to create device %s: %s" % (hn, res.stderr))

            # Parse created device ID from response
            created_id = ""
            start_idx = res.stdout.find('"id"')
            if start_idx != -1:
                id_colon = res.stdout.find(":", start_idx)
                id_quote = res.stdout.find('"', id_colon)
                id_end = res.stdout.find('"', id_quote + 1)
                created_id = res.stdout[id_quote + 1:id_end]

            # Get full device info
            dev_res = ctx.run([
                "curl", "-s",
                "-H", "X-Auth-Token: " + auth_token,
                "-H", "Accept: application/json",
                "https://api.packet.net/v1/devices/" + created_id
            ])
            if dev_res.rc != 0:
                fail("Failed to fetch device %s details: %s" % (created_id, dev_res.stderr))

            # Parse device details (same as above)
            dev = {"id": created_id, "hostname": hn}
            dev_str = dev_res.stdout
            # Extract state
            st_start = dev_str.find('"state"')
            if st_start != -1:
                st_colon = dev_str.find(":", st_start)
                st_quote = dev_str.find('"', st_colon)
                st_end = dev_str.find('"', st_quote + 1)
                dev["state"] = dev_str[st_quote + 1:st_end]
            # Extract locked
            lk_start = dev_str.find('"locked"')
            if lk_start != -1:
                lk_colon = dev_str.find(":", lk_start)
                lk_val = dev_str[lk_colon + 1:lk_colon + 6].strip()
                dev["locked"] = lk_val.startswith("true")
            # Extract ip_addresses
            ip_start = dev_str.find('"ip_addresses"')
            if ip_start != -1:
                ip_colon = dev_str.find(":", ip_start)
                ip_brace = dev_str.find("[", ip_colon)
                ip_end = ip_brace + 1
                depth = 1
                while ip_end < len(dev_str) and depth > 0:
                    if dev_str[ip_end] == '[':
                        depth += 1
                    elif dev_str[ip_end] == ']':
                        depth -= 1
                    ip_end += 1
                ip_list_str = dev_str[ip_brace:ip_end]
                # Parse IPs
                public_v4 = ""
                public_v6 = ""
                private_v4 = ""
                private_v6 = ""
                # Split by objects
                ip_entries = ip_list_str.split("{")
                for j in range(1, len(ip_entries)):
                    ip_entry = "{" + ip_entries[j].rstrip().rstrip(",") + "}"
                    # address
                    addr_start = ip_entry.find('"address"')
                    if addr_start != -1:
                        addr_colon = ip_entry.find(":", addr_start)
                        addr_quote = ip_entry.find('"', addr_colon)
                        addr_end = ip_entry.find('"', addr_quote + 1)
                        addr = ip_entry[addr_quote + 1:addr_end]
                    # address_family
                    af_start = ip_entry.find('"address_family"')
                    if af_start != -1:
                        af_colon = ip_entry.find(":", af_start)
                        af_end = ip_entry.find(",", af_colon)
                        if af_end == -1:
                            af_end = ip_entry.find("}", af_colon)
                        af_val = ip_entry[af_colon + 1:af_end].strip()
                        af = int(af_val)
                    # public
                    pub_start = ip_entry.find('"public"')
                    if pub_start != -1:
                        pub_colon = ip_entry.find(":", pub_start)
                        pub_val = ip_entry[pub_colon + 1:pub_colon + 6].strip()
                        pub = pub_val.startswith("true")

                    if pub and af == 4:
                        public_v4 = addr
                    elif pub and af == 6:
                        public_v6 = addr
                    elif not pub and af == 4:
                        private_v4 = addr
                    elif not pub and af == 6:
                        private_v6 = addr

                dev["public_ipv4"] = public_v4
                dev["public_ipv6"] = public_v6
                dev["private_ipv4"] = private_v4
                dev["private_ipv6"] = private_v6

            created_devices.append(dev)

    # Wait for public IP if requested
    if len(created_devices) > 0 and wait_for_ipv != None:
        timeout_end = ctx.time() + wait_timeout
        while ctx.time() < timeout_end:
            all_have_ip = True
            for d in created_devices:
                if wait_for_ipv == 4:
                    if d["public_ipv4"] == "":
                        all_have_ip = False
                        break
                elif wait_for_ipv == 6:
                    if d["public_ipv6"] == "":
                        all_have_ip = False
                        break
            if all_have_ip:
                break
            # Sleep 5 seconds (simulate with a small delay)
            for _ in range(5):
                if ctx.check_mode:
                    break
                # In real scenario would sleep, but in Starlark we can't
                pass
        if ctx.check_mode:
            return {"changed": True, "msg": "would create devices and wait for IP", "devices": []}
        # In check_mode, ctx.time() doesn't advance so we'll exit loop immediately

    # Wait for active state if requested
    if state == "active":
        timeout_end = ctx.time() + wait_timeout
        all_active = False
        while ctx.time() < timeout_end:
            all_active = True
            # Refresh devices
            all_devices = target_devices + created_devices
            for d in all_devices:
                if d["state"] != "active":
                    all_active = False
                    # Force refresh by querying again
                    res = ctx.run([
                        "curl", "-s",
                        "-H", "X-Auth-Token: " + auth_token,
                        "-H", "Accept: application/json",
                        "https://api.packet.net/v1/devices/" + d["id"]
                    ])
                    if res.rc == 0:
                        # Update state
                        st_start = res.stdout.find('"state"')
                        if st_start != -1:
                            st_colon = res.stdout.find(":", st_start)
                            st_quote = res.stdout.find('"', st_colon)
                            st_end = res.stdout.find('"', st_quote + 1)
                            d["state"] = res.stdout[st_quote + 1:st_end]
                    break
            if all_active:
                break
            for _ in range(5):
                if ctx.check_mode:
                    break
                pass

        if ctx.check_mode:
            return {"changed": True, "msg": "would wait for active state", "devices": []}

    # Build result
    all_devices = target_devices + created_devices
    formatted_devices = []
    for d in all_devices:
        dev_obj = {
            "id": d["id"],
            "hostname": d["hostname"],
            "public_ipv4": d.get("public_ipv4", ""),
            "private_ipv4": d.get("private_ipv4", ""),
            "public_ipv6": d.get("public_ipv6", ""),
            "locked": d["locked"],
            "state": d["state"],
            "tags": []
        }
        formatted_devices.append(dev_obj)

    changed = len(target_devices) > 0 or len(created_devices) > 0

    return {"changed": changed, "msg": "Processed devices", "devices": formatted_devices}
