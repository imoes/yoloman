def main(ctx, params):
    name = params["volume_name"]
    state = params.get("state", "present")
    driver = params.get("driver", "local")
    driver_options = params.get("driver_options", {})
    labels = params.get("labels")
    recreate = params.get("recreate", "never")

    # Build base docker CLI command
    docker_cmd = ["docker", "volume"]

    # Probe current volume existence
    res = ctx.run(docker_cmd + ["inspect", name], mutates=False, ok_codes=[0, 1])
    volume_exists = res.rc == 0

    # Handle absent state
    if state == "absent":
        if not volume_exists:
            return {"changed": False, "msg": "volume " + name + " does not exist"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would remove volume " + name}
        res = ctx.run(docker_cmd + ["rm", name], mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would remove volume " + name}
        if res.rc != 0:
            fail("failed to remove volume " + name + ": " + res.stderr)
        return {"changed": True, "msg": "removed volume " + name}

    # Handle present state
    if state == "present":
        if not volume_exists:
            # Create volume
            if ctx.check_mode:
                return {"changed": True, "msg": "would create volume " + name}
            # Build create command
            cmd = docker_cmd + ["create", "--driver", driver]
            if driver_options:
                # Convert dict to --opt key=value pairs
                for k, v in driver_options.items():
                    cmd += ["--opt", str(k) + "=" + str(v)]
            if labels:
                for k, v in labels.items():
                    cmd += ["--label", str(k) + "=" + str(v)]
            cmd += [name]
            res = ctx.run(cmd, mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would create volume " + name}
            if res.rc != 0:
                fail("failed to create volume " + name + ": " + res.stderr)
            return {"changed": True, "msg": "created volume " + name}

        # Volume exists — handle recreate logic
        if recreate == "never":
            return {"changed": False, "msg": "volume " + name + " already exists and recreate=never"}
        elif recreate == "always":
            if ctx.check_mode:
                return {"changed": True, "msg": "would recreate volume " + name}
            res = ctx.run(docker_cmd + ["rm", name], mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would recreate volume " + name}
            if res.rc != 0:
                fail("failed to remove existing volume " + name + ": " + res.stderr)
            # Recreate
            cmd = docker_cmd + ["create", "--driver", driver]
            if driver_options:
                for k, v in driver_options.items():
                    cmd += ["--opt", str(k) + "=" + str(v)]
            if labels:
                for k, v in labels.items():
                    cmd += ["--label", str(k) + "=" + str(v)]
            cmd += [name]
            res = ctx.run(cmd, mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would recreate volume " + name}
            if res.rc != 0:
                fail("failed to recreate volume " + name + ": " + res.stderr)
            return {"changed": True, "msg": "recreated volume " + name}
        elif recreate == "options-changed":
            # For options-changed, we would need to inspect and compare driver/opts/labels
            # But JSON parsing is not available in Starlark — fail with clear message
            fail("docker_volume: 'options-changed' recreate mode requires volume inspection — JSON parsing not available in Starlark runtime")
        else:
            fail("unsupported recreate value: " + recreate)

    fail("unsupported state: " + state)
