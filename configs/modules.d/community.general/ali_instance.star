def main(ctx, params):
    state = params.get("state", "present")
    alicloud_region = params.get("alicloud_region")
    instance_ids = params.get("instance_ids", [])
    count = params.get("count", 1)
    image_id = params.get("image_id")
    instance_type = params.get("instance_type")
    force = params.get("force", False)
    dry_run = params.get("dry_run", False)
    
    # Basic validation
    if not alicloud_region:
        fail("alicloud_region is required")
    
    # Check mode support
    if ctx.check_mode:
        if state == "present" and (not image_id or not instance_type):
            return {"changed": False, "msg": "Missing required parameters for instance creation"}
        if state == "absent" and not instance_ids:
            return {"changed": False, "msg": "No instances specified for termination"}
        # Predict changes based on state
        if state in ["running", "stopped", "restarted", "absent"]:
            return {"changed": True, "msg": "would " + state + " instances"}
        return {"changed": False, "msg": "instance already in desired state"}
    
    # For non-check_mode, fail with clear message since Alibaba Cloud API is not available
    fail(
        "This module requires external Alibaba Cloud CLI or API integration. " +
        "The Starlark runtime cannot directly call Alibaba Cloud services. " +
        "Please use the 'run' module to invoke the Alibaba Cloud CLI (aliyun) or " +
        "implement this functionality via a custom tool that can interface with Alibaba Cloud."
    )
