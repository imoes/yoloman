def main(ctx, params):
    baseuri = params["baseuri"]
    category = params["category"]
    command_list = params["command"]
    username = params.get("username")
    password = params.get("password")
    auth_token = params.get("auth_token")
    timeout = str(params.get("timeout", 10))
    resource_id = params.get("resource_id")
    virtual_media = params.get("virtual_media", {})
    resource_uri = params.get("resource_uri")
    request_body = params.get("request_body")

    # Validate required parameters
    if category not in ["Manager", "Raw"]:
        fail("Invalid Category '%s'. Valid Categories = ['Manager', 'Raw']" % category)

    valid_commands = {
        "Manager": ["VirtualMediaInsert", "VirtualMediaEject"],
        "Raw": ["GetResource", "GetCollectionResource", "PatchResource", "PostResource"]
    }
    if category not in valid_commands:
        fail("Invalid Category '%s'" % category)
    for cmd in command_list:
        if cmd not in valid_commands[category]:
            fail("Invalid Command '%s' for category '%s'" % (cmd, category))

    # Build auth header
    if auth_token != None:
        auth_header = "X-Auth-Token: %s" % auth_token
    else:
        if username == None or password == None:
            fail("username and password are required when auth_token is not provided")
        auth_header = "Authorization: Basic %s:%s" % (username, password)

    # Base URI
    root_uri = "https://" + baseuri

    # Build headers string (timeout is handled by ctx.run timeout)
    headers = ["-H", "Content-Type: application/json", "-H", auth_header]
    curl_base = ["curl", "-sk", "-m", timeout] + headers

    # Track result and changed
    result = {}
    changed = False
    msg = ""

    # Execute each command
    for command in command_list:
        if category == "Manager":
            if command == "VirtualMediaInsert":
                if virtual_media.get("image_url") == None:
                    fail("image_url is required for VirtualMediaInsert")
                # Insert logic: find first empty slot and POST to InsertMedia action
                # For simplicity, we assume there's at least one available slot and
                # the action URI follows Redfish convention.
                # Get VirtualMedia collection
                res = ctx.run(curl_base + [root_uri + "/redfish/v1/Managers/" + (resource_id or "1") + "/VirtualMedia"])
                if res.rc != 0:
                    fail("failed to list VirtualMedia: " + res.stderr)
                data = res.stdout
                # Extract members (basic parsing)
                members = []
                lines = data.split("\n")
                for l in lines:
                    if '"@odata.id"' in l and "/VirtualMedia/" in l:
                        # simple extraction of @odata.id value
                        idx = l.find('"@odata.id"')
                        s = l[idx+len('"@odata.id"')+3:]
                        eid = s.find('"')
                        if eid > 0:
                            members.append(s[:eid])
                if len(members) == 0:
                    fail("no VirtualMedia resources found")
                # Use first available (naive approach for brevity)
                vm_uri = members[0]
                # Get the VirtualMedia resource to find InsertMedia action
                res = ctx.run(curl_base + [root_uri + vm_uri])
                if res.rc != 0:
                    fail("failed to get VirtualMedia: " + res.stderr)
                data = res.stdout
                if '"#VirtualMedia.InsertMedia"' not in data:
                    # Try PATCH fallback: check Allow header via OPTIONS or HEAD
                    res = ctx.run(curl_base + ["-X", "HEAD", root_uri + vm_uri])
                    if res.rc != 0:
                        fail("HEAD request failed for " + vm_uri)
                    allow = ""
                    for l in res.stderr.split("\n"):
                        if l.lower().startswith("allow:"):
                            allow = l.split(":",1)[1].strip()
                            break
                    if "PATCH" not in allow:
                        fail("InsertMedia action not found and PATCH not allowed on " + vm_uri)
                    # Construct PATCH payload
                    payload = {
                        "Image": virtual_media.get("image_url"),
                        "Inserted": virtual_media.get("inserted", True),
                        "WriteProtected": virtual_media.get("write_protected", True)
                    }
                    # PATCH via ctx.run
                    patch_cmd = curl_base + ["-X", "PATCH", "--data-binary", "@-", root_uri + vm_uri]
                    # Build JSON payload
                    payload_str = "{"
                    keys = list(payload.keys())
                    for i, k in enumerate(keys):
                        v = payload[k]
                        if type(v) == bool:
                            payload_str += '"%s":%s' % (k, "true" if v else "false")
                        else:
                            payload_str += '"%s":"%s"' % (k, str(v))
                        if i < len(keys)-1:
                            payload_str += ","
                    payload_str += "}"
                    # For check_mode, avoid actual write
                    if ctx.check_mode:
                        return {"changed": True, "msg": "would insert virtual media " + str(virtual_media.get("image_url"))}
                    res = ctx.run(patch_cmd, mutates=True, ok_codes=[0,204])
                    if res.rc != 0:
                        fail("PATCH failed: " + res.stderr)
                    changed = True
                    msg = "VirtualMedia inserted"
                else:
                    # POST to InsertMedia action
                    # Extract target URI (naive parsing)
                    action_target = ""
                    lines = data.split("\n")
                    for l in lines:
                        if '"target"' in l and '#VirtualMedia.InsertMedia' in lines[lines.index(l)-1] if lines.index(l)>0 else False:
                            idx = l.find('"target"')
                            s = l[idx+len('"target"')+3:]
                            eid = s.find('"')
                            if eid > 0:
                                action_target = s[:eid]
                                break
                    if action_target == "":
                        fail("InsertMedia action target not found")
                    # Build payload
                    payload = {"Image": virtual_media.get("image_url")}
                    insert_opt = ["Inserted", "WriteProtected", "UserName", "Password", "TransferProtocolType", "TransferMethod"]
                    for opt in insert_opt:
                        if opt.lower().replace(" ","") in ["inserted","write_protected","username","password","transferprotocoltype","transfermethod"]:
                            val = virtual_media.get(opt.lower())
                            if val != None:
                                payload[opt] = val
                    # POST
                    post_cmd = curl_base + ["-X", "POST", "--data-binary", "@-", root_uri + action_target]
                    payload_str = "{"
                    keys = list(payload.keys())
                    for i, k in enumerate(keys):
                        v = payload[k]
                        if type(v) == bool:
                            payload_str += '"%s":%s' % (k, "true" if v else "false")
                        else:
                            payload_str += '"%s":"%s"' % (k, str(v))
                        if i < len(keys)-1:
                            payload_str += ","
                    payload_str += "}"
                    if ctx.check_mode:
                        return {"changed": True, "msg": "would insert virtual media " + str(virtual_media.get("image_url"))}
                    res = ctx.run(post_cmd, mutates=True, ok_codes=[0,204])
                    if res.rc != 0:
                        fail("POST InsertMedia failed: " + res.stderr)
                    changed = True
                    msg = "VirtualMedia inserted"
            elif command == "VirtualMediaEject":
                # Eject logic: POST to EjectMedia action for all inserted media or specific image
                image_url = virtual_media.get("image_url")
                if image_url != None:
                    # Find specific media with this image
                    res = ctx.run(curl_base + [root_uri + "/redfish/v1/Managers/" + (resource_id or "1") + "/VirtualMedia"])
                    if res.rc != 0:
                        fail("failed to list VirtualMedia: " + res.stderr)
                    data = res.stdout
                    members = []
                    lines = data.split("\n")
                    for l in lines:
                        if '"@odata.id"' in l and "/VirtualMedia/" in l:
                            idx = l.find('"@odata.id"')
                            s = l[idx+len('"@odata.id"')+3:]
                            eid = s.find('"')
                            if eid > 0:
                                members.append(s[:eid])
                    found = False
                    for vm_uri in members:
                        res = ctx.run(curl_base + [root_uri + vm_uri])
                        if res.rc == 0 and image_url in res.stdout and '"Inserted":true' in res.stdout:
                            # Found matching inserted media
                            found = True
                            # Get EjectMedia target
                            res2 = ctx.run(curl_base + [root_uri + vm_uri])
                            if res2.rc != 0:
                                fail("failed to get VirtualMedia: " + res2.stderr)
                            data2 = res2.stdout
                            if '"#VirtualMedia.EjectMedia"' not in data2:
                                fail("EjectMedia action not found on " + vm_uri)
                            # Extract target
                            action_target = ""
                            lines2 = data2.split("\n")
                            for l in lines2:
                                if '"target"' in l:
                                    idx = l.find('"target"')
                                    s = l[idx+len('"target"')+3:]
                                    eid = s.find('"')
                                    if eid > 0:
                                        action_target = s[:eid]
                                        break
                            if action_target == "":
                                fail("EjectMedia action target not found")
                            # POST empty payload
                            post_cmd = curl_base + ["-X", "POST", "--data-binary", "@-", root_uri + action_target]
                            payload_str = "{}"
                            if ctx.check_mode:
                                return {"changed": True, "msg": "would eject virtual media " + image_url}
                            res3 = ctx.run(post_cmd, mutates=True, ok_codes=[0,204])
                            if res3.rc != 0:
                                fail("POST EjectMedia failed: " + res3.stderr)
                            changed = True
                            msg = "VirtualMedia ejected"
                            break
                    if not found:
                        # Already ejected
                        return {"changed": False, "msg": "VirtualMedia image '%s' already ejected" % image_url}
                else:
                    # Eject all inserted media (simplified)
                    res = ctx.run(curl_base + [root_uri + "/redfish/v1/Managers/" + (resource_id or "1") + "/VirtualMedia"])
                    if res.rc != 0:
                        fail("failed to list VirtualMedia: " + res.stderr)
                    data = res.stdout
                    members = []
                    lines = data.split("\n")
                    for l in lines:
                        if '"@odata.id"' in l and "/VirtualMedia/" in l:
                            idx = l.find('"@odata.id"')
                            s = l[idx+len('"@odata.id"')+3:]
                            eid = s.find('"')
                            if eid > 0:
                                members.append(s[:eid])
                    ejected = False
                    for vm_uri in members:
                        res = ctx.run(curl_base + [root_uri + vm_uri])
                        if res.rc == 0 and '"Inserted":true' in res.stdout:
                            # Get EjectMedia target
                            res2 = ctx.run(curl_base + [root_uri + vm_uri])
                            if res2.rc != 0:
                                fail("failed to get VirtualMedia: " + res2.stderr)
                            data2 = res2.stdout
                            if '"#VirtualMedia.EjectMedia"' not in data2:
                                continue
                            # Extract target
                            action_target = ""
                            lines2 = data2.split("\n")
                            for l in lines2:
                                if '"target"' in l:
                                    idx = l.find('"target"')
                                    s = l[idx+len('"target"')+3:]
                                    eid = s.find('"')
                                    if eid > 0:
                                        action_target = s[:eid]
                                        break
                            if action_target == "":
                                continue
                            # POST empty payload
                            post_cmd = curl_base + ["-X", "POST", "--data-binary", "@-", root_uri + action_target]
                            if ctx.check_mode:
                                return {"changed": True, "msg": "would eject all virtual media"}
                            res3 = ctx.run(post_cmd, mutates=True, ok_codes=[0,204])
                            if res3.rc != 0:
                                fail("POST EjectMedia failed: " + res3.stderr)
                            ejected = True
                            changed = True
                            msg = "VirtualMedia ejected"
                    if not ejected:
                        return {"changed": False, "msg": "No VirtualMedia image inserted"}
        elif category == "Raw":
            if command == "GetResource":
                if resource_uri == None:
                    fail("resource_uri is required for GetResource")
                res = ctx.run(curl_base + [root_uri + resource_uri])
                if res.rc != 0:
                    fail("GET failed: " + res.stderr)
                result = {"data": res.stdout}
                changed = False
                msg = "Resource retrieved"
            elif command == "GetCollectionResource":
                if resource_uri == None:
                    fail("resource_uri is required for GetCollectionResource")
                res = ctx.run(curl_base + [root_uri + resource_uri])
                if res.rc != 0:
                    fail("GET collection failed: " + res.stderr)
                collection_data = res.stdout
                # Extract members
                members = []
                lines = collection_data.split("\n")
                for l in lines:
                    if '"@odata.id"' in l:
                        idx = l.find('"@odata.id"')
                        s = l[idx+len('"@odata.id"')+3:]
                        eid = s.find('"')
                        if eid > 0:
                            members.append(s[:eid])
                data_list = []
                for member_uri in members:
                    res = ctx.run(curl_base + [root_uri + member_uri])
                    if res.rc == 0:
                        data_list.append(res.stdout)
                    else:
                        fail("GET member failed: " + res.stderr)
                result = {"data_list": data_list}
                changed = False
                msg = "Collection retrieved"
            elif command == "PatchResource":
                if resource_uri == None:
                    fail("resource_uri is required for PatchResource")
                if request_body == None:
                    fail("request_body is required for PatchResource")
                # Convert request_body to JSON
                body_str = "{"
                keys = list(request_body.keys())
                for i, k in enumerate(keys):
                    v = request_body[k]
                    if type(v) == bool:
                        body_str += '"%s":%s' % (k, "true" if v else "false")
                    else:
                        body_str += '"%s":"%s"' % (k, str(v))
                    if i < len(keys)-1:
                        body_str += ","
                body_str += "}"
                patch_cmd = curl_base + ["-X", "PATCH", "--data-binary", "@-", root_uri + resource_uri]
                if ctx.check_mode:
                    return {"changed": True, "msg": "would patch resource " + resource_uri}
                res = ctx.run(patch_cmd, mutates=True, ok_codes=[0,204])
                if res.rc != 0:
                    fail("PATCH failed: " + res.stderr)
                changed = True
                msg = "Resource patched"
            elif command == "PostResource":
                if resource_uri == None:
                    fail("resource_uri is required for PostResource")
                if request_body == None:
                    fail("request_body is required for PostResource")
                # Convert request_body to JSON
                body_str = "{"
                keys = list(request_body.keys())
                for i, k in enumerate(keys):
                    v = request_body[k]
                    if type(v) == bool:
                        body_str += '"%s":%s' % (k, "true" if v else "false")
                    else:
                        body_str += '"%s":"%s"' % (k, str(v))
                    if i < len(keys)-1:
                        body_str += ","
                body_str += "}"
                post_cmd = curl_base + ["-X", "POST", "--data-binary", "@-", root_uri + resource_uri]
                if ctx.check_mode:
                    return {"changed": True, "msg": "would post to resource " + resource_uri}
                res = ctx.run(post_cmd, mutates=True, ok_codes=[0,204])
                if res.rc != 0:
                    fail("POST failed: " + res.stderr)
                changed = True
                msg = "Resource posted"

    # Return final result
    if result == {}:
        return {"changed": changed, "msg": msg}
    else:
        return {"changed": changed, "msg": msg, "redfish_facts": result}
