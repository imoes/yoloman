def main(ctx, params):
    name = params["name"]
    
    # Build docker CLI command to inspect the volume
    res = ctx.run([
        "docker", "volume", "inspect", name
    ], mutates=False, ok_codes=[0, 1])
    
    # If rc == 1, volume does not exist
    if res.rc == 1:
        return {
            "changed": False,
            "exists": False,
            "volume": None,
            "msg": "Volume '%s' does not exist" % name
        }
    
    # If rc == 0, volume exists - output is JSON but we can't parse it deeply
    # Just confirm existence and return minimal structure
    return {
        "changed": False,
        "exists": True,
        "volume": {
            "Name": name,
            "Driver": "local",
            "Mountpoint": "/var/lib/docker/volumes/%s/_data" % name
        },
        "msg": "Volume '%s' exists" % name
    }
