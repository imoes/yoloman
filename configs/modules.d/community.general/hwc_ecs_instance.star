def main(ctx, params):
    state = params.get("state", "present")
    name = params["name"]
    availability_zone = params["availability_zone"]
    flavor_name = params["flavor_name"]
    image_id = params["image_id"]
    nics = params["nics"]
    root_volume = params["root_volume"]
    vpc_id = params["vpc_id"]
    admin_pass = params.get("admin_pass")
    description = params.get("description")
    eip_id = params.get("eip_id")
    enable_auto_recovery = params.get("enable_auto_recovery")
    enterprise_project_id = params.get("enterprise_project_id")
    security_groups = params.get("security_groups", [])
    server_metadata = params.get("server_metadata", {})
    server_tags = params.get("server_tags", {})
    ssh_key_name = params.get("ssh_key_name")
    user_data = params.get("user_data")
    data_volumes = params.get("data_volumes", [])
    
    # Check if instance exists by name and availability zone
    instance_id = _find_instance_by_name(ctx, name, availability_zone)
    
    if state == "present":
        if instance_id != None:
            # Instance exists - check if updates are needed
            current = _get_instance_details(ctx, instance_id)
            if _needs_update(params, current):
                if ctx.check_mode:
                    return {"changed": True, "msg": "would update instance", "id": instance_id}
                _update_instance(ctx, params, instance_id)
                return {"changed": True, "msg": "instance updated", "id": instance_id}
            return {"changed": False, "msg": "instance already exists", "id": instance_id}
        else:
            # Create new instance
            if ctx.check_mode:
                return {"changed": True, "msg": "would create instance", "name": name}
            instance_id = _create_instance(ctx, params)
            return {"changed": True, "msg": "instance created", "id": instance_id}
    else:  # absent
        if instance_id != None:
            if ctx.check_mode:
                return {"changed": True, "msg": "would delete instance", "id": instance_id}
            _delete_instance(ctx, instance_id)
            return {"changed": True, "msg": "instance deleted"}
        return {"changed": False, "msg": "instance not found"}


def _find_instance_by_name(ctx, name, availability_zone):
    # Search for existing instance by name and zone
    cmd = [
        "curl", "-s", "-X", "GET",
        "https://ecs.%s.myhuaweicloud.com/v1/%s/cloudservers/detail?name=%s&availability_zone=%s" % (
            ctx.facts().get("region", "cn-north-1"),
            "project_id_placeholder",  # Would need actual project ID
            name.replace(" ", "%20"),
            availability_zone
        ),
        "-H", "Authorization: Bearer %s" % ctx.facts().get("token", ""),
        "-H", "Content-Type: application/json"
    ]
    
    res = ctx.run(cmd)
    if res.rc != 0:
        return None
    
    # Simple JSON parsing without json module
    lines = res.stdout.split("\n")
    for line in lines:
        if '"id"' in line and '"name"' in line:
            parts = line.split(",")
            for part in parts:
                if '"id"' in part:
                    parts2 = part.split(":")
                    if len(parts2) >= 2:
                        return parts2[1].strip().replace('"', "")
    return None


def _get_instance_details(ctx, instance_id):
    cmd = [
        "curl", "-s", "-X", "GET",
        "https://ecs.%s.myhuaweicloud.com/v1/%s/cloudservers/%s" % (
            ctx.facts().get("region", "cn-north-1"),
            "project_id_placeholder",
            instance_id
        ),
        "-H", "Authorization: Bearer %s" % ctx.facts().get("token", ""),
        "-H", "Content-Type: application/json"
    ]
    
    res = ctx.run(cmd)
    if res.rc != 0:
        return None
    
    # Parse response - simplified
    return {"id": instance_id}


def _needs_update(params, current):
    # Check if any parameters need updating
    # This is a simplified version - real implementation would check all fields
    return False


def _update_instance(ctx, params, instance_id):
    # Update instance - simplified
    pass


def _create_instance(ctx, params):
    # Build request body
    body = {
        "server": {
            "name": params["name"],
            "availability_zone": params["availability_zone"],
            "flavorRef": params["flavor_name"],
            "imageRef": params["image_id"],
            "vpcid": params["vpc_id"],
            "nics": params["nics"]
        }
    }
    
    if params.get("admin_pass"):
        body["server"]["adminPass"] = params["admin_pass"]
    
    if params.get("description"):
        body["server"]["description"] = params["description"]
    
    if params.get("root_volume"):
        body["server"]["root_volume"] = params["root_volume"]
    
    # Send create request
    cmd = [
        "curl", "-s", "-X", "POST",
        "https://ecs.%s.myhuaweicloud.com/v1/%s/cloudservers" % (
            ctx.facts().get("region", "cn-north-1"),
            "project_id_placeholder"
        ),
        "-H", "Authorization: Bearer %s" % ctx.facts().get("token", ""),
        "-H", "Content-Type: application/json",
        "-d", str(body)
    ]
    
    res = ctx.run(cmd)
    if res.rc != 0:
        fail("Failed to create instance: " + res.stderr)
    
    # Extract instance ID from response
    instance_id = _extract_instance_id(res.stdout)
    if instance_id == None:
        fail("Could not extract instance ID from response")
    
    return instance_id


def _extract_instance_id(output):
    # Simple extraction from JSON-like output
    if '"id"' in output:
        parts = output.split('"id"')
        if len(parts) >= 2:
            second_part = parts[1]
            if ':' in second_part:
                value = second_part.split(':')[1].strip()
                if len(value) >= 2:
                    return value[1:-1]  # Remove quotes
    return None


def _delete_instance(ctx, instance_id):
    cmd = [
        "curl", "-s", "-X", "DELETE",
        "https://ecs.%s.myhuaweicloud.com/v1/%s/cloudservers/%s" % (
            ctx.facts().get("region", "cn-north-1"),
            "project_id_placeholder",
            instance_id
        ),
        "-H", "Authorization: Bearer %s" % ctx.facts().get("token", ""),
        "-H", "Content-Type: application/json"
    ]
    
    res = ctx.run(cmd)
    if res.rc != 0:
        fail("Failed to delete instance: " + res.stderr)
