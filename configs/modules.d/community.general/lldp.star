def main(ctx, params):
    # Check if lldpctl is available
    res = ctx.run(["which", "lldpctl"])
    if res.rc != 0:
        fail("lldpctl command not found")

    # Run lldpctl in keyvalue format
    res = ctx.run([ctx.run(["which", "lldpctl"]).stdout.strip(), "-f", "keyvalue"])
    if res.rc != 0:
        fail("lldpctl command failed. is lldpd running?")

    output = res.stdout
    if not output:
        fail("lldpctl produced no output")

    # Parse key=value format into nested dict
    output_dict = {}
    current_dict = {}
    lldp_entries = output.split("\n")

    for entry in lldp_entries:
        if entry.startswith("lldp"):
            path, value = entry.strip().split("=", 1)
            path = path.split(".")
            path_components, final = path[:-1], path[-1]
        else:
            value = current_dict[final] + "\n" + entry

        current_dict = output_dict
        for path_component in path_components:
            current_dict[path_component] = current_dict.get(path_component, {})
            current_dict = current_dict[path_component]
        current_dict[final] = value

    # Extract lldp data
    if "lldp" in output_dict:
        lldp_data = output_dict["lldp"]
        return {
            "changed": False,
            "msg": "LLDP information gathered successfully",
            "data": {"lldp": lldp_data}
        }
    else:
        fail("lldpctl did not return expected 'lldp' key")
