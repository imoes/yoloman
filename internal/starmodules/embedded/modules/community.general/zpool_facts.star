def main(ctx, params):
    name = params.get("name")
    parsable = params.get("parsable", False)
    properties = params.get("properties", "all")

    # Build zpool get command
    zpool = ctx.facts().get("zpool_bin", "zpool")
    cmd = [zpool, "get", "-H"]

    if parsable:
        cmd.append("-p")
    cmd.extend(["-o", "name,property,value", properties])

    if name != None:
        cmd.append(name)

    res = ctx.run(cmd)
    if res.rc != 0:
        fail("Failed to gather zpool facts: " + res.stderr)

    # Parse output
    pools = {}
    for line in res.stdout.split("\n"):
        if line == "":
            continue
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        pool_name, prop, value = parts
        if pool_name not in pools:
            pools[pool_name] = {"name": pool_name}
        pools[pool_name][prop] = value

    # Build result list
    facts = []
    for pool in sorted(pools.keys()):
        facts.append(pools[pool])

    # Handle missing pool case
    if name != None and len(facts) == 0:
        fail("ZFS pool %s does not exist!" % name)

    return {
        "changed": False,
        "msg": "gathered facts for %d ZFS pool(s)" % len(facts),
        "data": {
            "name": name if name != None else "",
            "parsable": parsable,
            "pools": facts,
        },
    }
