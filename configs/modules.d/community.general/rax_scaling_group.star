def main(ctx, params):
    name = params.get("name")
    state = params.get("state", "present")
    min_entities = params.get("min_entities")
    max_entities = params.get("max_entities")
    cooldown = params.get("cooldown", 300)
    flavor = params.get("flavor")
    image = params.get("image")
    server_name = params.get("server_name")

    # Required validation
    if name == None or flavor == None or image == None or server_name == None:
        fail("name, flavor, image, and server_name are required")
    if min_entities == None or max_entities == None:
        fail("min_entities and max_entities are required")
    if type(min_entities) != "int" or type(max_entities) != "int":
        fail("min_entities and max_entities must be integers")
    if type(cooldown) != "int":
        fail("cooldown must be an integer")

    # Validate integer ranges
    if not (min_entities >= 0 and min_entities <= 1000) or not (max_entities >= 0 and max_entities <= 1000):
        fail("min_entities and max_entities must be between 0 and 1000")

    if not (cooldown >= 0 and cooldown <= 86400):
        fail("cooldown must be between 0 and 86400")

    # Note: Full Rackspace Autoscale support requires pyrax which is not available in Starlark.
    # This module currently fails with a clear message indicating the limitation.
    fail("rax_scaling_group requires pyrax/Rackspace SDK which is not available in Starlark runtime; use rax CLI or API directly outside yolo-man")
