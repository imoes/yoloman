def main(ctx, params):
    key = params["key"]
    res = ctx.run(["gconftool-2", "--get", key], mutates=False)
    if res.rc != 0:
        fail("failed to retrieve key '" + key + "': " + res.stderr)
    value = res.stdout.rstrip() if res.stdout else None
    return {"changed": False, "msg": "retrieved value for " + key, "data": {"value": value}}
