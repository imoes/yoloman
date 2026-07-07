def main(ctx, params):
    state = params.get("state", "present")
    server_ids = params.get("server_ids", [])
    template = params.get("template")
    name = params.get("name")
    count = params.get("count", 1)
    exact_count = params.get("exact_count")
    count_group = params.get("count_group")
    type_ = params.get("type", "standard")
    
    # Check for unsupported options that would require CLC API
    unsupported_options = [
        "alias", "location", "cpu", "memory", "password", "ip_address",
        "storage_type", "primary_dns", "secondary_dns", "additional_disks",
        "custom_fields", "ttl", "managed_os", "description", "source_server_password",
        "cpu_autoscale_policy_id", "anti_affinity_policy_id", "anti_affinity_policy_name",
        "alert_policy_id", "alert_policy_name", "packages", "configuration_id",
        "os_type", "wait", "add_public_ip", "public_ip_protocol", "public_ip_ports",
        "network_id", "group"
    ]
    
    # Check for mutually exclusive options that aren't supported
    if exact_count != None and count != 1:
        fail("exact_count and count are mutually exclusive - not supported in Starlark runtime")
    
    if exact_count != None and state not in ("present",):
        fail("exact_count requires state=present - not supported in Starlark runtime")
    
    if (params.get("anti_affinity_policy_id") != None and 
        params.get("anti_affinity_policy_name") != None):
        fail("anti_affinity_policy_id and anti_affinity_policy_name are mutually exclusive - not supported in Starlark runtime")
    
    if (params.get("alert_policy_id") != None and 
        params.get("alert_policy_name") != None):
        fail("alert_policy_id and alert_policy_name are mutually exclusive - not supported in Starlark runtime")
    
    # Check CLC-specific requirements that can't be met in Starlark
    if state in ("started", "stopped", "absent"):
        if not server_ids:
            fail("server_ids is required for started, stopped, and absent states - not supported in Starlark runtime")
    
    if state == "present":
        if not template and type_ != "bareMetal":
            fail("template is required for present state when type is not bareMetal - not supported in Starlark runtime")
        if not name and type_ != "bareMetal":
            fail("name is required for present state when type is not bareMetal - not supported in Starlark runtime")
        if name and (len(name) < 1 or len(name) > 6):
            fail("name must be between 1 and 6 characters - not supported in Starlark runtime")
        if exact_count != None and not count_group:
            fail("exact_count requires count_group - not supported in Starlark runtime")
    
    # For bareMetal type requirements
    if type_ == "bareMetal":
        if not params.get("configuration_id"):
            fail("configuration_id is required for bareMetal servers - not supported in Starlark runtime")
        if not params.get("os_type") and state == "present":
            fail("os_type is required for bareMetal servers - not supported in Starlark runtime")
    
    # The CLC API integration is not available in the Starlark runtime
    fail("clc_server module requires CenturyLink Cloud API access which is not available in the Starlark runtime. Please use the original Ansible implementation with appropriate CLC credentials configured.")
