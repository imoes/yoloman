def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    mac = params.get("mac")
    etherstub = params.get("etherstub", False)
    mtu = params.get("mtu")
    force = params.get("force", False)

    # Mutually exclusive checks (as per Ansible's mutually_exclusive)
    if etherstub and mac != None:
        fail("parameters are mutually exclusive: etherstub and mac")
    if etherstub and mtu != None:
        fail("parameters are mutually exclusive: etherstub and mtu")

    # Required-if checks (as per Ansible's required_if)
    if not etherstub and mac == None:
        fail("parameter 'mac' is required when etherstub == False")
    if state == "absent":
        pass  # force is optional for absent; no failure needed per original

    # Validate MAC if present (simple format check)
    def is_valid_mac(mac):
        parts = mac.split(":")
        if len(parts) != 6:
            return False
        for part in parts:
            if len(part) != 2:
                return False
            for c in part:
                if c not in "0123456789abcdefABCDEF":
                    return False
        return True

    if mac != None and not is_valid_mac(mac):
        fail("Invalid MAC Address Value")

    nictag_exists_cmd = ctx.run(["which", "nictagadm"], mutates=False)
    if nictag_exists_cmd.rc != 0:
        fail("nictagadm binary not found")

    # Check existence
    res = ctx.run(["nictagadm", "exists", name], mutates=False)
    exists = res.rc == 0

    if state == "present":
        if exists:
            return {"changed": False, "msg": "nic tag %s already exists" % name}
        if ctx.check_mode:
            return {"changed": True, "msg": "would create nic tag %s" % name}

        cmd = ["nictagadm", "-v", "add"]
        if etherstub:
            cmd.append("-l")
        if mtu != None:
            cmd.append("-p")
            cmd.append("mtu=%s" % str(mtu))
        if mac != None:
            cmd.append("-p")
            cmd.append("mac=%s" % str(mac))
        cmd.append(name)

        res = ctx.run(cmd, mutates=True)
        if res.rc != 0:
            fail("failed to create nic tag %s: %s" % (name, res.stderr))
        return {"changed": True, "msg": "created nic tag %s" % name, "data": {"name": name, "mac": mac, "etherstub": etherstub, "mtu": mtu, "force": force, "state": state}}

    elif state == "absent":
        if not exists:
            return {"changed": False, "msg": "nic tag %s does not exist" % name}
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete nic tag %s" % name}

        cmd = ["nictagadm", "-v", "delete"]
        if force:
            cmd.append("-f")
        cmd.append(name)

        res = ctx.run(cmd, mutates=True)
        if res.rc != 0:
            fail("failed to delete nic tag %s: %s" % (name, res.stderr))
        return {"changed": True, "msg": "deleted nic tag %s" % name, "data": {"name": name, "mac": mac, "etherstub": etherstub, "mtu": mtu, "force": force, "state": state}}

    fail("unsupported state: " + state)
