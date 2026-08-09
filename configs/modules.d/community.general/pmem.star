def main(ctx, params):
    # Check required tools
    ipmctl_path = ctx.run(["which", "ipmctl"], mutates=False)
    if ipmctl_path.rc != 0:
        fail("ipmctl command not found")
    ndctl_path = ctx.run(["which", "ndctl"], mutates=False)
    if ndctl_path.rc != 0:
        fail("ndctl command not found")

    # Get parameters
    appdirect = params.get("appdirect")
    appdirect_interleaved = params.get("appdirect_interleaved", True)
    memorymode = params.get("memorymode")
    reserved = params.get("reserved")
    socket_list = params.get("socket")
    namespace_list = params.get("namespace")
    namespace_append = params.get("namespace_append", False)

    # Validation: one of appdirect/memorymode/socket/namespace required
    if (appdirect == None and memorymode == None and socket_list == None and namespace_list == None):
        fail("At least one of appdirect, memorymode, socket, or namespace must be specified")

    # Validation: mutual exclusivity
    if (appdirect != None or memorymode != None) and (socket_list != None or namespace_list != None):
        fail("appdirect/memorymode and socket/namespace are mutually exclusive")
    if socket_list != None and namespace_list != None:
        fail("socket and namespace are mutually exclusive")
    if namespace_list != None and namespace_append == False:
        fail("namespace_append must be true when namespace is specified")

    # Validation for non-socket mode
    if socket_list == None:
        if appdirect != None:
            if appdirect < 0 or appdirect > 100:
                fail("appdirect must be between 0 and 100")
        if memorymode != None:
            if memorymode < 0 or memorymode > 100:
                fail("memorymode must be between 0 and 100")
        if reserved != None:
            if reserved < 0 or reserved > 100:
                fail("reserved must be between 0 and 100")
        if reserved == None:
            if appdirect != None and memorymode != None and (appdirect + memorymode > 100):
                fail("appdirect + memorymode must be <= 100 when reserved is not specified")
        else:
            if appdirect != None and memorymode != None and (appdirect + memorymode + reserved != 100):
                fail("appdirect + memorymode + reserved must be 100")

    # Validate socket configuration
    if socket_list != None:
        for skt in socket_list:
            if skt.get("appdirect") < 0 or skt.get("appdirect") > 100:
                fail("appdirect must be between 0 and 100")
            if skt.get("memorymode") < 0 or skt.get("memorymode") > 100:
                fail("memorymode must be between 0 and 100")
            if skt.get("reserved") != None and (skt.get("reserved") < 0 or skt.get("reserved") > 100):
                fail("reserved must be between 0 and 100")

    # Remove existing namespaces if not namespace_append
    if namespace_list == None or namespace_append == False:
        # Get existing namespaces
        ns_list = ctx.run([ndctl_path.stdout.strip(), "list", "-N"], mutates=False)
        if ns_list.rc == 0 and ns_list.stdout.strip() != "":
            namespaces = ns_list.stdout.strip().split("\n")
            for ns_line in namespaces:
                if ns_line == "":
                    continue
                # Extract device name (simplified parsing)
                dev = ns_line.split('"dev":')[1].split('"')[1] if '"dev":' in ns_line else ""
                if dev:
                    ctx.run([ndctl_path.stdout.strip(), "disable-namespace", dev], mutates=False)
                    ctx.run([ndctl_path.stdout.strip(), "destroy-namespace", dev], mutates=False)

    # Delete current goals for non-namespace configurations
    if namespace_list == None:
        ctx.run([ipmctl_path.stdout.strip(), "delete", "-goal"], mutates=False)

    # Handle namespace configuration
    if namespace_list != None:
        for ns in namespace_list:
            cmd = [ndctl_path.stdout.strip(), "create-namespace", "-m", ns.get("mode")]
            if ns.get("type"):
                cmd += ["-t", ns.get("type")]
            if ns.get("size"):
                # Parse size suffix (k/K/KB, m/M/MB, g/G/GB, t/T/TB)
                size = ns.get("size")
                multiplier = 1
                if size.lower().endswith("kb") or size.lower().endswith("k"):
                    multiplier = 1024
                    size = size[:-2] if size.lower().endswith("kb") else size[:-1]
                elif size.lower().endswith("mb") or size.lower().endswith("m"):
                    multiplier = 1024*1024
                    size = size[:-2] if size.lower().endswith("mb") else size[:-1]
                elif size.lower().endswith("gb") or size.lower().endswith("g"):
                    multiplier = 1024*1024*1024
                    size = size[:-2] if size.lower().endswith("gb") else size[:-1]
                elif size.lower().endswith("tb") or size.lower().endswith("t"):
                    multiplier = 1024*1024*1024*1024
                    size = size[:-2] if size.lower().endswith("tb") else size[:-1]
                size_bytes = int(size) * multiplier
                cmd += ["-s", str(size_bytes)]
            ctx.run(cmd, mutates=True)

        # List namespaces
        ns_result = ctx.run([ndctl_path.stdout.strip(), "list", "-N"], mutates=False)
        result = []
        if ns_result.rc == 0 and ns_result.stdout.strip() != "":
            for line in ns_result.stdout.strip().split("\n"):
                if line != "":
                    ns = {"dev": line}
                    result.append(ns)
        return {"changed": True, "msg": "namespaces configured", "data": {"result": result, "reboot_required": False}}

    # Handle socket configuration
    if socket_list != None:
        result = []
        reboot_required = False
        for skt in socket_list:
            # Prepare ipmctl options
            ipmctl_opts = []
            ipmctl_opts += ["-socket", str(skt.get("id"))]
            ipmctl_opts += ["memorymode=" + str(skt.get("memorymode"))]
            res = skt.get("reserved")
            if res == None:
                res = 100 - skt.get("memorymode") - skt.get("appdirect")
            ipmctl_opts += ["reserved=" + str(res)]

            if skt.get("appdirect_interleaved", True):
                ipmctl_opts += ["PersistentMemoryType=AppDirect"]
            else:
                ipmctl_opts += ["PersistentMemoryType=AppDirectNotInterleaved"]

            # Dry run check
            cmd = [ipmctl_path.stdout.strip(), "create", "-goal"] + ipmctl_opts
            dry_run = ctx.run(cmd, mutates=False)
            if dry_run.rc != 0:
                fail("ipmctl create goal check failed: " + dry_run.stderr)

            # Actual creation
            cmd = [ipmctl_path.stdout.strip(), "create", "-u", "B", "-o", "nvmxml", "-force", "-goal"] + ipmctl_opts
            goal = ctx.run(cmd, mutates=True)
            if goal.rc != 0:
                fail("ipmctl create goal failed: " + goal.stderr)

            # Parse result
            # (Simplified parsing of nvmxml output)
            out = goal.stdout.strip()
            appdirect_size = 0
            memmode_size = 0
            reserved_size = 0
            # Very basic parsing - in production would use proper XML parsing
            for line in out.split("\n"):
                if "MemorySize" in line:
                    memmode_size += int(line.split(">")[1].split("<")[0])
                elif "AppDirect" in line and "Size" in line:
                    appdirect_size += int(line.split(">")[1].split("<")[0])

            # Get capacity for reserved calculation (simplified)
            cap_cmd = [ipmctl_path.stdout.strip(), "show", "-d", "Capacity", "-u", "B", "-o", "nvmxml", "-dimm", "-socket", str(skt.get("id"))]
            cap_out = ctx.run(cap_cmd, mutates=False)
            # Simplified capacity extraction
            for line in cap_out.stdout.strip().split("\n"):
                if "Capacity" in line:
                    reserved_size += int(line.split(">")[1].split("<")[0])

            total_size = appdirect_size + memmode_size + reserved_size
            if total_size > 0:
                reserved_size = total_size - appdirect_size - memmode_size

            result.append({
                "appdirect": appdirect_size,
                "memorymode": memmode_size,
                "reserved": reserved_size,
                "socket": skt.get("id")
            })
            reboot_required = True

        return {"changed": True, "msg": "socket configuration applied", "data": {"result": result, "reboot_required": reboot_required}}

    # Handle global (non-socket) configuration
    if appdirect != None or memorymode != None:
        ipmctl_opts = []
        if appdirect == None:
            appdirect = 0
        if memorymode == None:
            memorymode = 0

        ipmctl_opts += ["memorymode=" + str(memorymode)]
        res = reserved if reserved != None else 100 - memorymode - appdirect
        ipmctl_opts += ["reserved=" + str(res)]

        if appdirect_interleaved:
            ipmctl_opts += ["PersistentMemoryType=AppDirect"]
        else:
            ipmctl_opts += ["PersistentMemoryType=AppDirectNotInterleaved"]

        # Dry run check
        cmd = [ipmctl_path.stdout.strip(), "create", "-goal"] + ipmctl_opts
        dry_run = ctx.run(cmd, mutates=False)
        if dry_run.rc != 0:
            fail("ipmctl create goal check failed: " + dry_run.stderr)

        # Actual creation
        cmd = [ipmctl_path.stdout.strip(), "create", "-u", "B", "-o", "nvmxml", "-force", "-goal"] + ipmctl_opts
        goal = ctx.run(cmd, mutates=True)
        if goal.rc != 0:
            fail("ipmctl create goal failed: " + goal.stderr)

        # Parse result (simplified)
        out = goal.stdout.strip()
        appdirect_size = 0
        memmode_size = 0
        reserved_size = 0

        for line in out.split("\n"):
            if "MemorySize" in line:
                memmode_size += int(line.split(">")[1].split("<")[0])
            elif "AppDirect" in line and "Size" in line:
                appdirect_size += int(line.split(">")[1].split("<")[0])

        cap_cmd = [ipmctl_path.stdout.strip(), "show", "-d", "Capacity", "-u", "B", "-o", "nvmxml", "-dimm"]
        cap_out = ctx.run(cap_cmd, mutates=False)

        total_size = 0
        for line in cap_out.stdout.strip().split("\n"):
            if "Capacity" in line:
                total_size += int(line.split(">")[1].split("<")[0])

        reserved_size = total_size - appdirect_size - memmode_size

        result = [{
            "appdirect": appdirect_size,
            "memorymode": memmode_size,
            "reserved": reserved_size
        }]

        return {"changed": True, "msg": "memory configuration applied", "data": {"result": result, "reboot_required": True}}
