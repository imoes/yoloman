def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    
    # Required parameters validation
    if state == "present" and params.get("device") == None:
        fail("device is required when state is present")

    # Check if vdo binary exists
    res = ctx.run(["which", "vdo"], mutates=False)
    if res.rc != 0:
        fail("vdo command not found - is vdo installed?")
    vdocmd = "vdo"

    # Get inventory of VDO volumes
    res = ctx.run([vdocmd, "status"], mutates=False)
    vdolist = []
    if res.rc == 2 and "vdoconf.yml does not exist" in res.stderr:
        vdolist = []
    elif res.rc != 0:
        fail("Failed to list VDO volumes: " + res.stderr)
    else:
        # Simple parsing for vdo status YAML - look for "VDOs:" section
        lines = res.stdout.split("\n")
        in_vdos = False
        for line in lines:
            if line.strip() == "VDOs:":
                in_vdos = True
            elif in_vdos and line.strip().startswith("-") == False and line.strip().endswith(":"):
                # Extract volume name from line like "vdo1:"
                vol_name = line.strip().rstrip(":")
                if vol_name != "VDOs" and vol_name != "":
                    vdolist.append(vol_name)
            elif in_vdos and line.strip().startswith("- "):
                # Volume list entry
                vol_name = line.strip().lstrip("- ").rstrip(":")
                if vol_name != "":
                    vdolist.append(vol_name)
    
    # Get running volumes list
    res = ctx.run([vdocmd, "list"], mutates=False)
    runningvdolist = [v for v in res.stdout.split("\n") if v.strip() != ""]

    # Create new volume
    if name not in vdolist and state == "present":
        device = params.get("device")
        if device == None:
            fail("device is required when state is present")

        # Build vdo create command
        options = []
        if params.get("logicalsize") != None:
            options.append("--vdoLogicalSize=" + params["logicalsize"])
        if params.get("blockmapcachesize") != None:
            options.append("--blockMapCacheSize=" + params["blockmapcachesize"])
        if params.get("readcache") == "enabled":
            options.append("--readCache=enabled")
        if params.get("readcachesize") != None:
            options.append("--readCacheSize=" + params["readcachesize"])
        if params.get("slabsize") != None:
            options.append("--vdoSlabSize=" + params["slabsize"])
        if params.get("emulate512") == True:
            options.append("--emulate512=enabled")
        if params.get("indexmem") != None:
            options.append("--indexMem=" + params["indexmem"])
        if params.get("indexmode") == "sparse":
            options.append("--sparseIndex=enabled")
        if params.get("force") == True:
            options.append("--force")
        if params.get("ackthreads") != None:
            options.append("--vdoAckThreads=" + params["ackthreads"])
        if params.get("biothreads") != None:
            options.append("--vdoBioThreads=" + params["biothreads"])
        if params.get("cputhreads") != None:
            options.append("--vdoCpuThreads=" + params["cputhreads"])
        if params.get("logicalthreads") != None:
            options.append("--vdoLogicalThreads=" + params["logicalthreads"])
        if params.get("physicalthreads") != None:
            options.append("--vdoPhysicalThreads=" + params["physicalthreads"])

        # Create VDO volume
        cmd = [vdocmd, "create", "--name=" + name, "--device=" + device] + options
        res = ctx.run(cmd, mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would create VDO volume " + name}
        if res.rc != 0:
            fail("Failed to create VDO volume " + name + ": " + res.stderr)

        # Handle compression
        if params.get("compression") == "disabled":
            res = ctx.run([vdocmd, "disableCompression", "--name=" + name], mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would disable compression on " + name}
            if res.rc != 0:
                fail("Failed to disable compression on " + name + ": " + res.stderr)

        # Handle deduplication
        if params.get("deduplication") == "disabled":
            res = ctx.run([vdocmd, "disableDeduplication", "--name=" + name], mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would disable deduplication on " + name}
            if res.rc != 0:
                fail("Failed to disable deduplication on " + name + ": " + res.stderr)

        # Handle activated status
        if params.get("activated") == False:
            res = ctx.run([vdocmd, "deactivate", "--name=" + name], mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would deactivate " + name}
            if res.rc != 0:
                fail("Failed to deactivate " + name + ": " + res.stderr)

        # Handle running status
        if params.get("running") == False:
            res = ctx.run([vdocmd, "stop", "--name=" + name], mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would stop " + name}
            if res.rc != 0:
                fail("Failed to stop " + name + ": " + res.stderr)

        return {"changed": True, "msg": "created VDO volume " + name}

    # Modify existing volume
    if name in vdolist and state == "present":
        # Get current status
        res = ctx.run([vdocmd, "status"], mutates=False)
        if res.rc != 0:
            fail("Failed to get VDO status: " + res.stderr)
        
        # Parse status - extract relevant fields for the named volume
        status_output = res.stdout
        
        # Extract values from status output (simplified parsing)
        def get_status_field(field_name):
            for line in status_output.split("\n"):
                if line.strip().startswith(field_name + ":"):
                    return line.strip().split(":", 1)[1].strip()
            return None

        # Map status fields to params keys
        field_map = {
            "Logical size": "logicalsize",
            "Compression": "compression",
            "Deduplication": "deduplication",
            "Block map cache size": "blockmapcachesize",
            "Read cache": "readcache",
            "Read cache size": "readcachesize",
            "Configured write policy": "writepolicy",
            "Acknowledgement threads": "ackthreads",
            "Bio submission threads": "biothreads",
            "CPU-work threads": "cputhreads",
            "Logical threads": "logicalthreads",
            "Physical threads": "physicalthreads"
        }

        current = {}
        for status_field, param_key in field_map.items():
            val = get_status_field(status_field)
            if val != None:
                current[param_key] = val

        # Determine differences and build modify command
        diff_params = {}
        for param_key, val in current.items():
            playbook_val = params.get(param_key)
            if playbook_val != None and str(val) != str(playbook_val):
                diff_params[param_key] = playbook_val

        # Handle activated status
        activate_field = get_status_field("Activate")
        if params.get("activated") == False and activate_field == "enabled":
            res = ctx.run([vdocmd, "deactivate", "--name=" + name], mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would deactivate " + name}
            if res.rc != 0:
                fail("Failed to deactivate " + name + ": " + res.stderr)
            diff_params["activated"] = False  # Mark as changed

        if params.get("activated") == True and activate_field == "disabled":
            res = ctx.run([vdocmd, "activate", "--name=" + name], mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would activate " + name}
            if res.rc != 0:
                fail("Failed to activate " + name + ": " + res.stderr)
            diff_params["activated"] = True  # Mark as changed

        # Handle running status
        if params.get("running") == False and name in runningvdolist:
            res = ctx.run([vdocmd, "stop", "--name=" + name], mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would stop " + name}
            if res.rc != 0:
                fail("Failed to stop " + name + ": " + res.stderr)
            diff_params["running"] = False  # Mark as changed

        if params.get("running") == True and name not in runningvdolist:
            # Can only start if activated
            if activate_field == "enabled":
                res = ctx.run([vdocmd, "start", "--name=" + name], mutates=True)
                if res.skipped:
                    return {"changed": True, "msg": "would start " + name}
                if res.rc != 0:
                    fail("Failed to start " + name + ": " + res.stderr)
                diff_params["running"] = True  # Mark as changed
            elif params.get("activated") != False:
                # Would start if activated
                diff_params["running"] = True  # Mark as changed

        # Build modify command for thread/config params
        if len(diff_params) > 0:
            options = []
            for param_key, param_val in diff_params.items():
                if param_key == "compression":
                    if param_val == "disabled":
                        res = ctx.run([vdocmd, "disableCompression", "--name=" + name], mutates=True)
                        if res.skipped:
                            return {"changed": True, "msg": "would disable compression on " + name}
                        if res.rc != 0:
                            fail("Failed to disable compression on " + name + ": " + res.stderr)
                    else:
                        res = ctx.run([vdocmd, "enableCompression", "--name=" + name], mutates=True)
                        if res.skipped:
                            return {"changed": True, "msg": "would enable compression on " + name}
                        if res.rc != 0:
                            fail("Failed to enable compression on " + name + ": " + res.stderr)
                elif param_key == "deduplication":
                    if param_val == "disabled":
                        res = ctx.run([vdocmd, "disableDeduplication", "--name=" + name], mutates=True)
                        if res.skipped:
                            return {"changed": True, "msg": "would disable deduplication on " + name}
                        if res.rc != 0:
                            fail("Failed to disable deduplication on " + name + ": " + res.stderr)
                    else:
                        res = ctx.run([vdocmd, "enableDeduplication", "--name=" + name], mutates=True)
                        if res.skipped:
                            return {"changed": True, "msg": "would enable deduplication on " + name}
                        if res.rc != 0:
                            fail("Failed to enable deduplication on " + name + ": " + res.stderr)
                elif param_key == "writepolicy":
                    res = ctx.run([
                        vdocmd, "changeWritePolicy", "--name=" + name,
                        "--writePolicy=" + param_val
                    ], mutates=True)
                    if res.skipped:
                        return {"changed": True, "msg": "would change write policy for " + name}
                    if res.rc != 0:
                        fail("Failed to change write policy for " + name + ": " + res.stderr)
                elif param_key == "logicalsize":
                    # Logical size change implies growLogical
                    res = ctx.run([
                        vdocmd, "growLogical", "--name=" + name,
                        "--vdoLogicalSize=" + param_val
                    ], mutates=True)
                    if res.skipped:
                        return {"changed": True, "msg": "would grow logical size for " + name}
                    if res.rc != 0:
                        fail("Failed to grow logical size for " + name + ": " + res.stderr)
                else:
                    # Other params go in modify command
                    opt_map = {
                        "ackthreads": "--vdoAckThreads",
                        "biothreads": "--vdoBioThreads",
                        "cputhreads": "--vdoCpuThreads",
                        "logicalthreads": "--vdoLogicalThreads",
                        "physicalthreads": "--vdoPhysicalThreads",
                        "blockmapcachesize": "--blockMapCacheSize",
                        "readcachesize": "--readCacheSize"
                    }
                    if param_key in opt_map:
                        options.append(opt_map[param_key] + "=" + param_val)

            # Execute modify command if there are other options
            if len(options) > 0:
                res = ctx.run([vdocmd, "modify", "--name=" + name] + options, mutates=True)
                if res.skipped:
                    return {"changed": True, "msg": "would modify parameters for " + name}
                if res.rc != 0:
                    fail("Failed to modify " + name + ": " + res.stderr)

            # Handle growphysical if requested
            if params.get("growphysical") == True:
                device = params.get("device")
                if device != None:
                    res = ctx.run(["blockdev", "--getsz", device], mutates=False)
                    if res.rc == 0:
                        dev_sectors = int(res.stdout.strip())
                        dev_blocks = dev_sectors / 8
                        
                        # Get current physical blocks (simplified - would need exact parsing)
                        # For now, just attempt growPhysical
                        res = ctx.run([vdocmd, "growPhysical", "--name=" + name], mutates=True)
                        if res.skipped:
                            return {"changed": True, "msg": "would grow physical size for " + name}
                        if res.rc != 0:
                            # Don't fail if growPhysical fails - just report no change
                            pass

        # Check if already in desired state
        if len(diff_params) == 0:
            return {"changed": False, "msg": name + " already in desired state"}
        
        return {"changed": True, "msg": "modified parameters for " + name}

    # Remove volume
    if name in vdolist and state == "absent":
        res = ctx.run([vdocmd, "remove", "--name=" + name], mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would remove VDO volume " + name}
        if res.rc != 0:
            fail("Failed to remove VDO " + name + ": " + res.stderr)
        return {"changed": True, "msg": "removed VDO volume " + name}

    # Volume doesn't exist and state is absent - no change needed
    return {"changed": False, "msg": "VDO volume " + name + " does not exist"}
