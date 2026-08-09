def main(ctx, params):
    name = params["name"]
    # Build docker command args for network inspect
    args = ["docker", "network", "inspect", name]
    res = ctx.run(args, mutates=False)
    
    if res.rc == 0:
        # Parse JSON output manually (no json module available)
        # Expecting single-object array: [{"Name": "...", ...}]
        output = res.stdout.strip()
        if not output.startswith("[") or not output.endswith("]"):
            fail("unexpected docker network inspect output format")
        
        # Extract inner object (remove surrounding brackets and whitespace)
        inner = output[1:-1].strip()
        # Basic validation: should start with '{' and end with '}'
        if not (inner.startswith("{") and inner.endswith("}")):
            fail("unexpected docker network inspect output format")
        
        return {
            "changed": False,
            "exists": True,
            "network": inner  # Return raw JSON string as network fact
        }
    elif res.rc == 1 and ("No such network" in res.stderr or "network" in res.stderr.lower()):
        # Network does not exist (standard docker exit code 1 for missing network)
        return {
            "changed": False,
            "exists": False,
            "network": None
        }
    else:
        fail("docker network inspect failed: " + res.stderr)
