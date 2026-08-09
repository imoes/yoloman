def main(ctx, params):
    # Check for xenapi availability by running xe --version
    version_res = ctx.run(["xe", "--version"], mutates=False)
    if version_res.rc != 0:
        fail("python xen api required for this module")

    # Parse version string (e.g., "6.5.0-123456c")
    version_str = ""
    if version_res.stdout != None:
        lines = version_res.stdout.split("\n")
        if len(lines) > 0:
            version_str = lines[0].strip()
    # Extract major.minor.patch
    version_parts = version_str.split("-")[0].split(".") if version_str != "" else ["0", "0", "0"]
    version_major = 0
    version_minor = 0
    version_patch = 0
    if len(version_parts) > 0:
        version_major = int(version_parts[0])
    if len(version_parts) > 1:
        version_minor = int(version_parts[1])
    if len(version_parts) > 2:
        version_patch = int(version_parts[2])
    version = str(version_major) + "." + str(version_minor) + "." + str(version_patch)

    # Map versions to codenames
    codes = {
        "5.5.0": "george",
        "5.6.100": "oxford",
        "6.0.0": "boston",
        "6.1.0": "tampa",
        "6.2.0": "clearwater"
    }
    codename = codes.get(version, None)

    # Gather data: networks
    networks_res = ctx.run(["xe", "network-list", "--minimal"], mutates=False)
    networks_uuids = networks_res.stdout.strip().split(',') if networks_res.stdout.strip() != "" else []
    xs_networks = {}
    for uuid in networks_uuids:
        if uuid == "":
            continue
        rec_res = ctx.run(["xe", "network-param-get", "uuid=" + uuid, "param-name=all"], mutates=False)
        if rec_res.rc != 0:
            continue
        record = {"ref": uuid}
        for line in rec_res.stdout.splitlines():
            line = line.strip()
            idx = line.find("=")
            if idx > 0:
                key = line[:idx]
                val = line[idx+1:]
                record[key] = val
        name_label = record.get("name-label", uuid)
        xs_networks[name_label] = record

    # Gather data: pifs
    pifs_res = ctx.run(["xe", "pif-list", "--minimal"], mutates=False)
    pifs_uuids = pifs_res.stdout.strip().split(',') if pifs_res.stdout.strip() != "" else []
    xs_pifs = {}
    devicenums = range(0, 7)
    for uuid in pifs_uuids:
        if uuid == "":
            continue
        rec_res = ctx.run(["xe", "pif-param-get", "uuid=" + uuid, "param-name=all"], mutates=False)
        if rec_res.rc != 0:
            continue
        record = {"ref": uuid}
        for line in rec_res.stdout.splitlines():
            line = line.strip()
            idx = line.find("=")
            if idx > 0:
                key = line[:idx]
                val = line[idx+1:]
                record[key] = val
        device = record.get("device", "")
        for eth in devicenums:
            interface_name = "eth" + str(eth)
            bond_name = "bond" + str(eth)
            if device == interface_name:
                xs_pifs[interface_name] = record
                break
            elif device == bond_name:
                xs_pifs[bond_name] = record
                break

    # Gather data: vlans
    vlans_res = ctx.run(["xe", "vlan-list", "--minimal"], mutates=False)
    vlans_uuids = vlans_res.stdout.strip().split(',') if vlans_res.stdout.strip() != "" else []
    xs_vlans = {}
    for uuid in vlans_uuids:
        if uuid == "":
            continue
        rec_res = ctx.run(["xe", "vlan-param-get", "uuid=" + uuid, "param-name=all"], mutates=False)
        if rec_res.rc != 0:
            continue
        record = {"ref": uuid}
        for line in rec_res.stdout.splitlines():
            line = line.strip()
            idx = line.find("=")
            if idx > 0:
                key = line[:idx]
                val = line[idx+1:]
                record[key] = val
        tag = record.get("tag", "")
        if tag == "":
            tag = uuid  # fallback
        xs_vlans[tag] = record

    # Gather data: vms
    vms_res = ctx.run(["xe", "vm-list", "--minimal"], mutates=False)
    vms_uuids = vms_res.stdout.strip().split(',') if vms_res.stdout.strip() != "" else []
    xs_vms = {}
    for uuid in vms_uuids:
        if uuid == "":
            continue
        rec_res = ctx.run(["xe", "vm-param-get", "uuid=" + uuid, "param-name=all"], mutates=False)
        if rec_res.rc != 0:
            continue
        record = {"ref": uuid}
        for line in rec_res.stdout.splitlines():
            line = line.strip()
            idx = line.find("=")
            if idx > 0:
                key = line[:idx]
                val = line[idx+1:]
                record[key] = val
        name_label = record.get("name-label", uuid)
        xs_vms[name_label] = record

    # Gather data: srs
    srs_res = ctx.run(["xe", "sr-list", "--minimal"], mutates=False)
    srs_uuids = srs_res.stdout.strip().split(',') if srs_res.stdout.strip() != "" else []
    xs_srs = {}
    for uuid in srs_uuids:
        if uuid == "":
            continue
        rec_res = ctx.run(["xe", "sr-param-get", "uuid=" + uuid, "param-name=all"], mutates=False)
        if rec_res.rc != 0:
            continue
        record = {"ref": uuid}
        for line in rec_res.stdout.splitlines():
            line = line.strip()
            idx = line.find("=")
            if idx > 0:
                key = line[:idx]
                val = line[idx+1:]
                record[key] = val
        name_label = record.get("name-label", uuid)
        xs_srs[name_label] = record

    # Build facts dict
    data = {
        "xenserver_version": version,
        "xenserver_codename": codename
    }
    if len(xs_networks) > 0:
        data["xs_networks"] = xs_networks
    if len(xs_pifs) > 0:
        data["xs_pifs"] = xs_pifs
    if len(xs_vlans) > 0:
        data["xs_vlans"] = xs_vlans
    if len(xs_vms) > 0:
        data["xs_vms"] = xs_vms
    if len(xs_srs) > 0:
        data["xs_srs"] = xs_srs

    return {"changed": False, "msg": "facts collected", "data": data}
