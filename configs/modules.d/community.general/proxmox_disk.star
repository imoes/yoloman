def main(ctx, params):
    # Extract required params
    api_host = params["api_host"]
    api_user = params["api_user"]
    disk = params["disk"]
    state = params.get("state", "present")
    name = params.get("name")
    vmid = params.get("vmid")

    # Validate disk format
    disk_regex = compile(r'^([a-z]+)([0-9]+)$')
    disk_bus = disk_regex.sub(r'\1', disk)
    disk_number = int(disk_regex.sub(r'\2', disk))

    supported_buses = ["ide", "scsi", "sata", "virtio", "unused"]
    bus_ranges = {"ide": range(0, 4), "scsi": range(0, 31), "sata": range(0, 6), "virtio": range(0, 16), "unused": range(0, 256)}

    if disk_bus not in supported_buses:
        fail("Unsupported disk bus: %s" % disk_bus)
    if disk_number not in bus_ranges[disk_bus]:
        fail("Disk %s number not in range %s..%s" % (disk, bus_ranges[disk_bus][0], bus_ranges[disk_bus][-1]))

    # VM resolution
    vmid = vmid if vmid != None else find_vmid_by_name(ctx, params, name)
    if vmid == None:
        fail("Cannot find VM with name '%s' or vmid" % name)

    # Get VM config
    vm_info = ctx.run(["curl", "-s", "-k", "-X", "GET",
                       "-H", "Content-Type: application/json",
                       "-H", "Authorization: PVEAPIToken=%s=%s" % (api_user, params.get("api_token_secret", "")) if params.get("api_token_id") != None else "-u %s:%s" % (api_user, params.get("api_password", "")),
                       "https://%s:8006/api2/json/nodes/%s/qemu/%s/config" % (api_host, get_node_for_vmid(ctx, api_host, vmid), vmid)],
                      ok_codes=[0, 200])

    if vm_info.rc != 0:
        fail("Failed to retrieve VM config: " + vm_info.stderr)

    vm_config = parse_simple_json(vm_info.stdout)

    # Validate disk exists for state operations
    if state in ["resized", "moved"] and disk not in vm_config:
        fail("Unable to process missing disk %s in VM %s" % (disk, vmid))

    # State handling
    if state == "present":
        return handle_present(ctx, params, api_host, api_user, vmid, vm_config, disk)
    elif state == "detached":
        return handle_detached(ctx, params, api_host, api_user, vmid, disk, vm_config)
    elif state == "moved":
        return handle_moved(ctx, params, api_host, api_user, vmid, disk, vm_config)
    elif state == "resized":
        return handle_resized(ctx, params, api_host, api_user, vmid, disk, vm_config, params.get("size"))
    elif state == "absent":
        return handle_absent(ctx, params, api_host, api_user, vmid, disk, vm_config)
    else:
        fail("Unsupported state: %s" % state)


# Helper functions
def find_vmid_by_name(ctx, params, name):
    if name == None:
        return None
    api_host = params.get("api_host", "")
    api_user = params.get("api_user", "")
    
    auth_header = ""
    if params.get("api_token_id") != None:
        auth_header = "Authorization: PVEAPIToken=%s=%s" % (api_user, params.get("api_token_secret", ""))
    else:
        auth_header = "-u %s:%s" % (api_user, params.get("api_password", ""))
    
    res = ctx.run(["curl", "-s", "-k", "-X", "GET",
                   "-H", "Content-Type: application/json",
                   "-H", auth_header,
                   "https://%s:8006/api2/json/nodes" % api_host],
                  ok_codes=[0])
    if res.rc != 0:
        return None
    
    nodes = parse_simple_json(res.stdout)
    for node in nodes:
        vm_res = ctx.run(["curl", "-s", "-k", "-X", "GET",
                          "-H", "Content-Type: application/json",
                          "-H", auth_header,
                          "https://%s:8006/api2/json/nodes/%s/qemu" % (api_host, node["node"])],
                         ok_codes=[0])
        if vm_res.rc == 0:
            vms = parse_simple_json(vm_res.stdout)
            for vm in vms:
                if vm.get("name") == name:
                    return vm["vmid"]
    return None


def get_node_for_vmid(ctx, api_host, vmid):
    # In real implementation, this would query all nodes
    # For simplicity, assume it's on the api_host node
    return api_host


def parse_simple_json(s):
    # Very basic JSON parser for proxmox response
    # Only handles simple flat dict with strings/integers
    result = {}
    s = s.strip()
    if not s.startswith("{") or not s.endswith("}"):
        return result
    content = s[1:-1]
    parts = content.split(",")
    for part in parts:
        if ":" in part:
            key, value = part.split(":", 1)
            key = key.strip().strip('"')
            value = value.strip()
            if value.startswith('"'):
                value = value[1:-1]
            elif value.isdigit():
                value = int(value)
            elif value.replace('.', '', 1).isdigit():
                value = float(value)
            result[key] = value
    return result


def build_config_string(params, existing_config=None, for_import=False):
    config_parts = []
    
    # ISO image handling
    iso_image = params.get("iso_image")
    if iso_image != None:
        return iso_image
    
    # Import handling
    import_from = params.get("import_from")
    if import_from != None:
        config_parts.append("%s:0,import-from=%s" % (params.get("storage"), import_from))
    else:
        storage = params.get("storage")
        if storage != None:
            if existing_config != None:
                # Preserve volume
                volume = existing_config.get("volume")
                if volume != None:
                    config_parts.append(volume)
                else:
                    config_parts.append("%s:0" % storage)
            else:
                size = params.get("size")
                if params.get("media") != "cdrom" and size != None:
                    config_parts.append("%s:%s" % (storage, size))
                else:
                    config_parts.append(storage)
    
    # Add options
    options = [
        ("aio", params.get("aio")), ("backup", params.get("backup")), ("bps_max_length", params.get("bps_max_length")),
        ("bps_rd_max_length", params.get("bps_rd_max_length")), ("bps_wr_max_length", params.get("bps_wr_max_length")),
        ("cache", params.get("cache")), ("cyls", params.get("cyls")), ("detect_zeroes", params.get("detect_zeroes")),
        ("discard", params.get("discard")), ("format", params.get("format")), ("heads", params.get("heads")),
        ("iops", params.get("iops")), ("iops_max", params.get("iops_max")), ("iops_max_length", params.get("iops_max_length")),
        ("iops_rd", params.get("iops_rd")), ("iops_rd_max", params.get("iops_rd_max")), ("iops_rd_max_length", params.get("iops_rd_max_length")),
        ("iops_wr", params.get("iops_wr")), ("iops_wr_max", params.get("iops_wr_max")), ("iops_wr_max_length", params.get("iops_wr_max_length")),
        ("iothread", params.get("iothread")), ("mbps", params.get("mbps")), ("mbps_max", params.get("mbps_max")), ("mbps_rd", params.get("mbps_rd")),
        ("mbps_rd_max", params.get("mbps_rd_max")), ("mbps_wr", params.get("mbps_wr")), ("mbps_wr_max", params.get("mbps_wr_max")),
        ("queues", params.get("queues")), ("replicate", params.get("replicate")), ("rerror", params.get("rerror")), ("ro", params.get("ro")),
        ("scsiblock", params.get("scsiblock")), ("secs", params.get("secs")), ("serial", params.get("serial")), ("shared", params.get("shared")),
        ("snapshot", params.get("snapshot")), ("ssd", params.get("ssd")), ("trans", params.get("trans")), ("werror", params.get("werror")), ("wwn", params.get("wwn"))
    ]
    
    for key, value in options:
        if value != None:
            # Convert bool to int
            if type(value) == "bool":
                value = 1 if value else 0
            config_parts.append("%s=%s" % (key, str(value)))
    
    return ",".join(config_parts)


def handle_present(ctx, params, api_host, api_user, vmid, vm_config, disk):
    create = params.get("create", "regular")
    
    if create == "disabled" and disk not in vm_config:
        return {"changed": False, "msg": "Disk %s not found in VM %s and creation was disabled in parameters." % (disk, vmid)}
    
    if (create == "regular" and disk not in vm_config) or (create == "forced"):
        # Create new disk
        config_str = build_config_string(params, None, True)
        
        res = ctx.run(["curl", "-s", "-k", "-X", "POST",
                       "-H", "Content-Type: application/json",
                       "-H", "Authorization: PVEAPIToken=%s=%s" % (api_user, params.get("api_token_secret", "")) if params.get("api_token_id") != None else "-u %s:%s" % (api_user, params.get("api_password", "")),
                       "-d", "%s=%s" % (disk, config_str),
                       "https://%s:8006/api2/json/nodes/%s/qemu/%s/config" % (api_host, get_node_for_vmid(ctx, api_host, vmid), vmid)],
                      ok_codes=[0, 200])
        
        if res.rc != 0:
            fail("Failed to create disk: " + res.stderr)
        
        return {"changed": True, "msg": "Disk %s created in VM %s" % (disk, vmid)}
    
    if disk in vm_config:
        # Update existing disk
        config_str = build_config_string(params, parse_simple_json(vm_config[disk]), False)
        
        res = ctx.run(["curl", "-s", "-k", "-X", "POST",
                       "-H", "Content-Type: application/json",
                       "-H", "Authorization: PVEAPIToken=%s=%s" % (api_user, params.get("api_token_secret", "")) if params.get("api_token_id") != None else "-u %s:%s" % (api_user, params.get("api_password", "")),
                       "-d", "%s=%s" % (disk, config_str),
                       "https://%s:8006/api2/json/nodes/%s/qemu/%s/config" % (api_host, get_node_for_vmid(ctx, api_host, vmid), vmid)],
                      ok_codes=[0, 200])
        
        if res.rc != 0:
            fail("Failed to update disk: " + res.stderr)
        
        return {"changed": True, "msg": "Disk %s updated in VM %s" % (disk, vmid)}
    
    return {"changed": False, "msg": "Disk %s is up to date in VM %s" % (disk, vmid)}


def handle_detached(ctx, params, api_host, api_user, vmid, disk, vm_config):
    disk_bus = disk[:4] if len(disk) >= 4 else disk
    if disk_bus == "unused":
        return {"changed": False, "msg": "Disk %s already detached in VM %s" % (disk, vmid)}
    
    if disk not in vm_config:
        return {"changed": False, "msg": "Disk %s not present in VM %s config" % (disk, vmid)}
    
    res = ctx.run(["curl", "-s", "-k", "-X", "PUT",
                   "-H", "Content-Type: application/json",
                   "-H", "Authorization: PVEAPIToken=%s=%s" % (api_user, params.get("api_token_secret", "")) if params.get("api_token_id") != None else "-u %s:%s" % (api_user, params.get("api_password", "")),
                   "-d", "idlist=%s&force=0" % disk,
                   "https://%s:8006/api2/json/nodes/%s/qemu/%s/unlink" % (api_host, get_node_for_vmid(ctx, api_host, vmid), vmid)],
                  ok_codes=[0, 200])
    
    if res.rc != 0:
        fail("Failed to detach disk: " + res.stderr)
    
    return {"changed": True, "msg": "Disk %s detached from VM %s" % (disk, vmid)}


def handle_moved(ctx, params, api_host, api_user, vmid, disk, vm_config):
    disk_config = parse_simple_json(vm_config[disk])
    disk_storage = disk_config.get("storage_name")
    
    # Prepare move parameters
    move_params = []
    move_params.append("disk=%s" % disk)
    move_params.append("vmid=%s" % vmid)
    if params.get("bwlimit") != None:
        move_params.append("bwlimit=%s" % params.get("bwlimit"))
    if params.get("target_storage") != None:
        move_params.append("storage=%s" % params.get("target_storage"))
    if params.get("target_disk") != None:
        move_params.append("target-disk=%s" % params.get("target_disk"))
    if params.get("target_vmid") != None:
        move_params.append("target-vmid=%s" % params.get("target_vmid"))
    if params.get("format") != None:
        move_params.append("format=%s" % params.get("format"))
    if params.get("delete_moved") != None:
        move_params.append("delete=%s" % (1 if params.get("delete_moved") else 0))
    
    res = ctx.run(["curl", "-s", "-k", "-X", "POST",
                   "-H", "Content-Type: application/x-www-form-urlencoded",
                   "-H", "Authorization: PVEAPIToken=%s=%s" % (api_user, params.get("api_token_secret", "")) if params.get("api_token_id") != None else "-u %s:%s" % (api_user, params.get("api_password", "")),
                   "-d", "&".join(move_params),
                   "https://%s:8006/api2/json/nodes/%s/qemu/%s/move_disk" % (api_host, get_node_for_vmid(ctx, api_host, vmid), vmid)],
                  ok_codes=[0, 200])
    
    if res.rc != 0:
        fail("Failed to move disk: " + res.stderr)
    
    return {"changed": True, "msg": "Disk %s moved from VM %s storage %s" % (disk, vmid, disk_storage)}


def handle_resized(ctx, params, api_host, api_user, vmid, disk, vm_config, size):
    if size == None:
        fail("Size is required when state is resized")
    
    disk_config = parse_simple_json(vm_config[disk])
    actual_size = disk_config.get("size")
    
    if size == actual_size:
        return {"changed": False, "msg": "Disk %s is already %s size" % (disk, size)}
    
    res = ctx.run(["curl", "-s", "-k", "-X", "POST",
                   "-H", "Content-Type: application/json",
                   "-H", "Authorization: PVEAPIToken=%s=%s" % (api_user, params.get("api_token_secret", "")) if params.get("api_token_id") != None else "-u %s:%s" % (api_user, params.get("api_password", "")),
                   "-d", "disk=%s&size=%s" % (disk, size),
                   "https://%s:8006/api2/json/nodes/%s/qemu/%s/resize" % (api_host, get_node_for_vmid(ctx, api_host, vmid), vmid)],
                  ok_codes=[0, 200])
    
    if res.rc != 0:
        fail("Failed to resize disk: " + res.stderr)
    
    return {"changed": True, "msg": "Disk %s resized in VM %s" % (disk, vmid)}


def handle_absent(ctx, params, api_host, api_user, vmid, disk, vm_config):
    if disk not in vm_config:
        return {"changed": False, "msg": "Disk %s is already absent in VM %s" % (disk, vmid)}
    
    res = ctx.run(["curl", "-s", "-k", "-X", "PUT",
                   "-H", "Content-Type: application/json",
                   "-H", "Authorization: PVEAPIToken=%s=%s" % (api_user, params.get("api_token_secret", "")) if params.get("api_token_id") != None else "-u %s:%s" % (api_user, params.get("api_password", "")),
                   "-d", "idlist=%s&force=1" % disk,
                   "https://%s:8006/api2/json/nodes/%s/qemu/%s/unlink" % (api_host, get_node_for_vmid(ctx, api_host, vmid), vmid)],
                  ok_codes=[0, 200])
    
    if res.rc != 0:
        fail("Failed to remove disk: " + res.stderr)
    
    return {"changed": True, "msg": "Disk %s removed from VM %s" % (disk, vmid)}
