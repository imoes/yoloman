def main(ctx, params):
    state = params.get("state", "present")
    if state not in ["present", "absent"]:
        fail("state must be either present or absent")

    entity_id = params.get("entity_id")
    label = params.get("label")
    check_type = params.get("check_type")
    monitoring_zones_poll = params.get("monitoring_zones_poll")
    target_hostname = params.get("target_hostname")
    target_alias = params.get("target_alias")
    details = params.get("details", {})
    disabled = params.get("disabled", False)
    metadata = params.get("metadata", {})
    period = params.get("period")
    timeout = params.get("timeout")

    # Validate required parameters
    if entity_id == None:
        fail("entity_id is required")
    if label == None:
        fail("label is required")
    if check_type == None:
        fail("check_type is required")

    # For remote.* checks, either target_alias or target_hostname is required
    if check_type.startswith("remote.") and target_alias == None and target_hostname == None:
        fail("One of target_alias and target_hostname is required for remote.* checks")

    # For agent.* checks, target_alias and target_hostname are prohibited
    if check_type.startswith("agent.") and (target_alias != None or target_hostname != None):
        fail("target_alias and target_hostname are prohibited for agent.* checks")

    # Coerce monitoring_zones_poll to list if provided and not a list
    if monitoring_zones_poll != None and type(monitoring_zones_poll) != "list":
        monitoring_zones_poll = [monitoring_zones_poll]

    # Convert period and timeout to int if provided
    if period != None:
        period = int(period)
    if timeout != None:
        timeout = int(timeout)

    # Check if pyrax is available (simulated by checking environment)
    # In practice, this would require the agent to provide a way to load pyrax
    # Since Starlark has no import and pyrax is not available, fail with message
    fail("pyrax is not available in Starlark runtime. This module requires the Rackspace Cloud Monitoring API client (pyrax).")

    # The rest of the logic would use pyrax.cloud_monitoring to:
    # 1. Get entity by entity_id
    # 2. List existing checks and filter by label
    # 3. Create/update/delete checks based on state
    # Since we cannot use pyrax, the module cannot function in Starlark without additional capabilities
