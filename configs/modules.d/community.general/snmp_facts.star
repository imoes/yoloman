def main(ctx, params):
    host = params["host"]
    version = params["version"]
    community = params.get("community")
    username = params.get("username")
    level = params.get("level")
    integrity = params.get("integrity")
    privacy = params.get("privacy")
    authkey = params.get("authkey")
    privkey = params.get("privkey")
    timeout = params.get("timeout")
    retries = params.get("retries")

    # Validate version-specific requirements
    if version in ("v2", "v2c"):
        if community == None:
            fail("Community not set when using snmp version 2")

    if version == "v3":
        if username == None:
            fail("Username not set when using snmp version 3")
        if level == None:
            fail("Level not set when using snmp version 3")
        if integrity == None:
            fail("Integrity not set when using snmp version 3")

        # Validate authPriv requires privacy and privkey
        if level == "authPriv":
            if privacy == None:
                fail("Privacy algorithm not set when using authPriv")
            if privkey == None:
                fail("Privacy key not set when using authPriv")

    # Check for check_mode only - snmp_facts is read-only so no mutation needed
    if ctx.check_mode:
        return {"changed": False, "msg": "Gathering facts in check mode", "data": {}}

    # Build CLI arguments for snmpget/snmpwalk
    base_args = ["snmpget", "-v", version, "-c", community if version in ("v2", "v2c") else "nocommunity", "-On"]
    if version == "v3":
        base_args = ["snmpget", "-v", version]
        if level == "authPriv":
            base_args.extend(["-u", username, "-l", level, "-a", integrity, "-A", authkey, "-x", privacy, "-X", privkey])
        else:  # authNoPriv
            base_args.extend(["-u", username, "-l", level, "-a", integrity, "-A", authkey])

    if timeout != None:
        base_args.extend(["-t", str(timeout)])
    if retries != None:
        base_args.extend(["-r", str(retries)])

    base_args.append(host)

    # Helper to run snmpget with retry support
    def snmpget(oids):
        args = base_args + oids
        res = ctx.run(args)
        if res.rc != 0:
            fail("snmpget failed: " + res.stderr)
        return res.stdout

    # Helper to run snmpwalk
    def snmpwalk(oids):
        # Convert snmpget to snmpwalk by replacing first arg
        walk_args = base_args.copy()
        walk_args[0] = "snmpwalk"
        walk_args.extend(oids)
        res = ctx.run(walk_args)
        if res.rc != 0:
            fail("snmpwalk failed: " + res.stderr)
        return res.stdout

    # Get system info (sysDescr, sysObjectId, sysUpTime, sysContact, sysName, sysLocation)
    sys_oids = [
        "1.3.6.1.2.1.1.1.0",  # sysDescr
        "1.3.6.1.2.1.1.2.0",  # sysObjectId
        "1.3.6.1.2.1.1.3.0",  # sysUpTime
        "1.3.6.1.2.1.1.4.0",  # sysContact
        "1.3.6.1.2.1.1.5.0",  # sysName
        "1.3.6.1.2.1.1.6.0",  # sysLocation
    ]

    sys_output = snmpget(sys_oids)

    # Parse sys_output to populate system facts
    result = {}
    for line in sys_output.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid = parts[0].strip()
        value = parts[1].strip()
        # Remove leading "STRING:", "OBJECT IDENTIFIER:", etc.
        if value.startswith("STRING:"):
            value = value[7:]
            # Remove surrounding quotes if present
            if value.startswith('"') and value.endswith('"'):
                value = value[1:-1]
        elif value.startswith("OBJECT IDENTIFIER:"):
            value = value[18:].strip()
        elif value.startswith("Timeticks:"):
            # Convert to integer (hundredths of seconds)
            t = value[10:].strip()
            if t.startswith("(") and t.endswith(")"):
                t = t[1:-1]
            # Extract numeric value (e.g., "(123456) 1:03:45.60" -> "123456")
            idx = t.find(")")
            if idx != -1:
                t = t[:idx].strip()
            value = t

        if oid == "1.3.6.1.2.1.1.1.0":
            result["ansible_sysdescr"] = value
        elif oid == "1.3.6.1.2.1.1.2.0":
            result["ansible_sysobjectid"] = value
        elif oid == "1.3.6.1.2.1.1.3.0":
            result["ansible_sysuptime"] = int(value) if value.isdigit() else 0
        elif oid == "1.3.6.1.2.1.1.4.0":
            result["ansible_syscontact"] = value
        elif oid == "1.3.6.1.2.1.1.5.0":
            result["ansible_sysname"] = value
        elif oid == "1.3.6.1.2.1.1.6.0":
            result["ansible_syslocation"] = value

    # Get interfaces via snmpwalk
    if_oids = [
        "1.3.6.1.2.1.2.2.1.1",  # ifIndex
        "1.3.6.1.2.1.2.2.1.2",  # ifDescr
        "1.3.6.1.2.1.2.2.1.4",  # ifMtu
        "1.3.6.1.2.1.2.2.1.5",  # ifSpeed
        "1.3.6.1.2.1.2.2.1.6",  # ifPhysAddress
        "1.3.6.1.2.1.2.2.1.7",  # ifAdminStatus
        "1.3.6.1.2.1.2.2.1.8",  # ifOperStatus
        "1.3.6.1.2.1.31.1.1.1.18",  # ifAlias
    ]

    if_output = snmpwalk(if_oids)

    interfaces = {}
    all_ipv4_addresses = []
    ipv4_networks = {}

    def lookup_adminstatus(int_adminstatus):
        adminstatus_options = {
            1: 'up',
            2: 'down',
            3: 'testing'
        }
        return adminstatus_options.get(int(int_adminstatus), "") if int_adminstatus.isdigit() else ""

    def lookup_operstatus(int_operstatus):
        operstatus_options = {
            1: 'up',
            2: 'down',
            3: 'testing',
            4: 'unknown',
            5: 'dormant',
            6: 'notPresent',
            7: 'lowerLayerDown'
        }
        return operstatus_options.get(int(int_operstatus), "") if int_operstatus.isdigit() else ""

    for line in if_output.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid = parts[0].strip()
        value = parts[1].strip()

        # Extract index from OID (last number after the OID base)
        if "1.3.6.1.2.1.2.2.1." in oid:
            oid_base = oid.rsplit(".", 1)[0]
            idx_str = oid.rsplit(".", 1)[-1]
            if not idx_str.isdigit():
                continue
            idx = int(idx_str)
            if idx not in interfaces:
                interfaces[idx] = {}

            if "1.3.6.1.2.1.2.2.1.1" in oid_base:  # ifIndex
                interfaces[idx]["ifindex"] = value
            elif "1.3.6.1.2.1.2.2.1.2" in oid_base:  # ifDescr
                interfaces[idx]["name"] = value
            elif "1.3.6.1.2.1.2.2.1.4" in oid_base:  # ifMtu
                interfaces[idx]["mtu"] = value
            elif "1.3.6.1.2.1.2.2.1.5" in oid_base:  # ifSpeed
                interfaces[idx]["speed"] = value
            elif "1.3.6.1.2.1.2.2.1.6" in oid_base:  # ifPhysAddress
                # Decode MAC
                mac = value
                if mac.startswith("STRING:"):
                    mac = mac[7:]
                if mac.startswith("0x"):
                    mac = mac[2:]
                interfaces[idx]["mac"] = mac
            elif "1.3.6.1.2.1.2.2.1.7" in oid_base:  # ifAdminStatus
                interfaces[idx]["adminstatus"] = lookup_adminstatus(value)
            elif "1.3.6.1.2.1.2.2.1.8" in oid_base:  # ifOperStatus
                interfaces[idx]["operstatus"] = lookup_operstatus(value)
            elif "1.3.6.1.31.1.1.1.18" in oid_base:  # ifAlias
                if value.startswith("STRING:"):
                    value = value[7:]
                interfaces[idx]["description"] = value

    # Get IP addresses
    ip_oids = [
        "1.3.6.1.2.1.4.20.1.1",  # ipAdEntAddr
        "1.3.6.1.2.1.4.20.1.2",  # ipAdEntIfIndex
        "1.3.6.1.2.1.4.20.1.3",  # ipAdEntNetMask
    ]

    ip_output = snmpwalk(ip_oids)

    for line in ip_output.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(" = ", 1)
        if len(parts) != 2:
            continue
        oid = parts[0].strip()
        value = parts[1].strip()

        if "1.3.6.1.2.1.4.20.1.1" in oid:  # ipAdEntAddr
            # Extract IP from OID like ...1.1.2.3.4 -> 1.2.3.4
            ip_parts = oid.rsplit(".", 4)[-4:]
            ip = ".".join(ip_parts)
            if ip not in ipv4_networks:
                ipv4_networks[ip] = {}
            ipv4_networks[ip]["address"] = value
            all_ipv4_addresses.append(value)
        elif "1.3.6.1.2.1.4.20.1.2" in oid:  # ipAdEntIfIndex
            ip_parts = oid.rsplit(".", 4)[-4:]
            ip = ".".join(ip_parts)
            if ip not in ipv4_networks:
                ipv4_networks[ip] = {}
            ipv4_networks[ip]["interface"] = value
        elif "1.3.6.1.2.1.4.20.1.3" in oid:  # ipAdEntNetMask
            ip_parts = oid.rsplit(".", 4)[-4:]
            ip = ".".join(ip_parts)
            if ip not in ipv4_networks:
                ipv4_networks[ip] = {}
            ipv4_networks[ip]["netmask"] = value

    # Build interface IPv4 mappings
    interface_to_ipv4 = {}
    for ip in ipv4_networks:
        network = ipv4_networks[ip]
        interface = network.get("interface")
        if interface and interface.isdigit():
            ifidx = int(interface)
            if ifidx not in interface_to_ipv4:
                interface_to_ipv4[ifidx] = []
            interface_to_ipv4[ifidx].append({
                "address": network.get("address", ""),
                "netmask": network.get("netmask", "")
            })
            if ifidx not in interfaces:
                interfaces[ifidx] = {}

    for ifidx in interface_to_ipv4:
        interfaces[ifidx]["ipv4"] = interface_to_ipv4[ifidx]

    result["ansible_interfaces"] = interfaces
    result["ansible_all_ipv4_addresses"] = all_ipv4_addresses

    return {"changed": False, "msg": "SNMP facts gathered successfully", "data": result}
