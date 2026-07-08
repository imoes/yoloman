def main(ctx, params):
    name = params.get("name")
    address = params.get("address")
    server_id = params.get("id")
    
    # Validate mutually exclusive parameters
    provided_ids = 0
    if name != None:
        provided_ids = provided_ids + 1
    if address != None:
        provided_ids = provided_ids + 1
    if server_id != None:
        provided_ids = provided_ids + 1
    
    if provided_ids == 0:
        fail("One of 'name', 'address', or 'id' is required")
    if provided_ids > 1:
        fail("Parameters 'name', 'address', and 'id' are mutually exclusive")

    # Since pyrax and external Rackspace API access are unavailable in Starlark,
    # this module cannot perform real Rackspace facts gathering.
    # Per contract: fail clearly when core functionality is unimplementable.
    fail("The rax_facts module requires pyrax and cannot be implemented in Starlark runtime. Please use the original Ansible Python module.")
