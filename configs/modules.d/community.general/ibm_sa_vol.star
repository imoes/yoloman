def main(ctx, params):
    vol = params["vol"]
    state = params.get("state", "present")
    pool = params.get("pool")
    size = params.get("size")
    endpoints = params["endpoints"]
    username = params["username"]
    password = params["password"]

    # Check if volume exists using xcli
    res = ctx.run([
        "xcli", "-y", "-c", "vol_list", "vol=" + vol,
        "-h", endpoints, "-u", username, "-p", password
    ])
    if res.rc != 0:
        fail("failed to list volume: " + res.stderr)
    
    volume_exists = "vol=" + vol in res.stdout

    if state == "present":
        if volume_exists:
            return {"changed": False, "msg": "volume " + vol + " already exists"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would create volume " + vol}
        
        # Build vol_create command
        cmd = ["xcli", "-y", "-c", "vol_create", "vol=" + vol]
        if pool != None:
            cmd.append("pool=" + pool)
        if size != None:
            cmd.append("size=" + size)
        cmd.extend(["-h", endpoints, "-u", username, "-p", password])
        
        res = ctx.run(cmd, mutates=True)
        if res.rc != 0:
            fail("failed to create volume " + vol + ": " + res.stderr)
        return {"changed": True, "msg": "created volume " + vol}
    
    elif state == "absent":
        if not volume_exists:
            return {"changed": False, "msg": "volume " + vol + " does not exist"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete volume " + vol}
        
        res = ctx.run([
            "xcli", "-y", "-c", "vol_delete", "vol=" + vol,
            "-h", endpoints, "-u", username, "-p", password
        ], mutates=True)
        if res.rc != 0:
            fail("failed to delete volume " + vol + ": " + res.stderr)
        return {"changed": True, "msg": "deleted volume " + vol}
    
    fail("unsupported state: " + state)
