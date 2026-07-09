def main(ctx, params):
    name = params["name"]
    recurse = params.get("recurse", False)
    parsable = params.get("parsable", False)
    properties = params.get("properties", "all")
    type_ = params.get("type", "all")
    depth = params.get("depth", 0)

    # Validate type
    if type_ not in ["all", "filesystem", "volume", "snapshot", "bookmark"]:
        fail("invalid type '%s': must be one of: all, filesystem, volume, snapshot, bookmark" % type_)

    # Check dataset exists
    res = ctx.run(["zfs", "list", name], mutates=False)
    if res.rc != 0:
        fail("ZFS dataset %s does not exist" % name)

    # Build zfs get command
    cmd = ["zfs", "get", "-H"]
    if parsable:
        cmd.append("-p")
    if recurse:
        cmd.append("-r")
    if depth != 0:
        cmd.append("-d")
        cmd.append(str(depth))
    if type_ != "all":
        cmd.append("-t")
        cmd.append(type_)
    cmd.extend(["-o", "name,property,value", properties, name])

    res = ctx.run(cmd, mutates=False)
    if res.rc != 0:
        fail("Error while getting ZFS dataset facts: %s" % res.stderr.strip())

    # Parse output
    datasets = {}
    for line in res.stdout.split("\n"):
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        dataset, prop, value = parts
        if dataset not in datasets:
            datasets[dataset] = {}
        datasets[dataset][prop] = value

    # Add dataset names
    for dataset in datasets:
        datasets[dataset]["name"] = dataset

    # Build result (contract shape: changed + msg + data)
    dataset_list = list(datasets.values())
    return {
        "changed": False,
        "msg": "gathered facts for %d ZFS dataset(s)" % len(dataset_list),
        "data": {
            "name": name,
            "parsable": parsable,
            "recurse": recurse,
            "datasets": dataset_list,
        },
    }
