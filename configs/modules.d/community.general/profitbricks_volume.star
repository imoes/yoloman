def main(ctx, params):
    # Required params validation (matching original module behavior)
    if not params.get("subscription_user"):
        fail("subscription_user parameter is required")
    if not params.get("subscription_password"):
        fail("subscription_password parameter is required")

    datacenter = params.get("datacenter")
    name = params.get("name")
    size = params.get("size", 10)
    bus = params.get("bus", "VIRTIO")
    image = params.get("image")
    image_password = params.get("image_password")
    ssh_keys = params.get("ssh_keys", [])
    disk_type = params.get("disk_type", "HDD")
    licence_type = params.get("licence_type", "UNKNOWN")
    count = params.get("count", 1)
    auto_increment = params.get("auto_increment", True)
    instance_ids = params.get("instance_ids", [])
    state = params.get("state", "present")
    server = params.get("server")
    wait = params.get("wait", True)
    wait_timeout = params.get("wait_timeout", 600)

    # Validate bus/disk_type/license_type choices
    if bus not in ["IDE", "VIRTIO"]:
        fail("bus must be one of: IDE, VIRTIO")
    if disk_type not in ["HDD", "SSD"]:
        fail("disk_type must be one of: HDD, SSD")
    if state not in ["present", "absent"]:
        fail("state must be one of: present, absent")

    # In check_mode, we can only predict changes — no real API calls.
    if ctx.check_mode:
        if state == "absent":
            # Check if any instance_ids refer to existing volumes
            # (This is a simplified prediction; in real Starlark, no ProfitBricks API exists)
            if len(instance_ids) > 0:
                return {"changed": True, "msg": "would remove volume(s) " + ", ".join(instance_ids)}
            return {"changed": False, "msg": "no volumes to remove"}
        else:  # present
            if not datacenter or not name:
                return {"changed": False, "msg": "datacenter and name are required"}
            return {"changed": True, "msg": "would create " + str(count) + " volume(s)"}

    # For non-check_mode, we would normally call an external API.
    # Since this Starlark runtime has no ProfitBricks SDK integration,
    # we fail with a clear message indicating the module requires external API support.
    fail("profitbricks_volume module requires a custom ProfitBricks API client implementation via ctx.* builtins; this is not provided in the standard Starlark runtime")
