def main(ctx, params):
    name = params["name"]
    state = params.get("state", "present")
    source = params.get("source", "local")
    force_source = params.get("force_source", False)
    force_absent = params.get("force_absent", False)
    force_tag = params.get("force_tag", False)
    tag = params.get("tag", "latest")
    build = params.get("build", {})
    archive_path = params.get("archive_path")
    load_path = params.get("load_path")
    repository = params.get("repository")
    push = params.get("push", False)

    # Helper to check image presence (by name:tag or ID)
    def find_image_by_name():
        res = ctx.run(["docker", "images", "--format", "{{.Repository}}:{{.Tag}} {{.ID}}"])
        if res.rc != 0:
            fail("failed to list images: " + res.stderr)
        for line in res.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            repo_tag = parts[0]
            image_id = parts[1]
            if repo_tag == name + ":" + tag or repo_tag == name or (repo_tag == name and tag == "latest"):
                return {"Id": image_id}
        return None

    # Helper to check if image exists by ID
    def find_image_by_id(image_id):
        res = ctx.run(["docker", "images", "--format", "{{.ID}}", "-q", image_id])
        if res.rc != 0:
            fail("failed to inspect image by ID: " + res.stderr)
        lines = [l.strip() for l in res.stdout.splitlines() if l.strip()]
        return {"Id": image_id} if lines else None

    # Determine current state
    current_image = find_image_by_name() if not is_image_id(name) else find_image_by_id(name)

    if state == "absent":
        if current_image == None:
            return {"changed": False, "msg": "Image does not exist"}
        if ctx.check_mode:
            return {"changed": True, "msg": "would remove image " + name}
        res = ctx.run(["docker", "rmi", "-f", name] if force_absent else ["docker", "rmi", name], mutates=True)
        if res.skipped:
            return {"changed": True, "msg": "would remove image " + name}
        if res.rc != 0:
            fail("failed to remove image " + name + ": " + res.stderr)
        return {"changed": True, "msg": "removed image " + name}

    if state == "present":
        if current_image != None and not force_source:
            if archive_path and not ctx.file_exists(archive_path):
                if ctx.check_mode:
                    return {"changed": True, "msg": "would archive image"}
                res = ctx.run(["docker", "save", name + ":" + tag, "-o", archive_path], mutates=True)
                if res.skipped:
                    return {"changed": True, "msg": "would archive image"}
                if res.rc != 0:
                    fail("failed to archive image: " + res.stderr)
                return {"changed": True, "msg": "archived image to " + archive_path}
            return {"changed": False, "msg": "image already present"}

        if source == "local":
            if ctx.check_mode:
                return {"changed": True, "msg": "would ensure image is present locally"}
            fail("Cannot find the image " + (name + ":" + tag) + " locally.")

        if source == "build":
            build_path = build.get("path")
            if not build_path or not ctx.file_exists(build_path):
                fail("build path " + build_path + " does not exist")
            if ctx.check_mode:
                return {"changed": True, "msg": "would build image " + name}
            build_cmd = ["docker", "build", "-t", name + ":" + tag, build_path]
            if build.get("args"):
                args = build.get("args")
                for k in args.keys():
                    v = args.get(k)
                    build_cmd.extend(["--build-arg", str(k) + "=" + str(v)])
            if build.get("dockerfile"):
                build_cmd.extend(["--file", build.get("dockerfile")])
            if build.get("pull", False):
                build_cmd.append("--pull")
            if build.get("rm", True):
                build_cmd.append("--rm")
            if build.get("nocache", False):
                build_cmd.append("--no-cache")
            res = ctx.run(build_cmd, mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would build image " + name}
            if res.rc != 0:
                fail("failed to build image " + name + ": " + res.stderr)
            return {"changed": True, "msg": "built image " + name}

        if source == "pull":
            if ctx.check_mode:
                return {"changed": True, "msg": "would pull image " + name + ":" + tag}
            pull_cmd = ["docker", "pull", name + ":" + tag]
            res = ctx.run(pull_cmd, mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would pull image " + name + ":" + tag}
            if res.rc != 0:
                fail("failed to pull image " + name + ":" + tag + ": " + res.stderr)
            return {"changed": True, "msg": "pulled image " + name + ":" + tag}

        if source == "load":
            if not load_path:
                fail("load_path must be provided when source=load")
            if not ctx.file_exists(load_path):
                fail("load path " + load_path + " does not exist")
            if ctx.check_mode:
                return {"changed": True, "msg": "would load image from " + load_path}
            load_cmd = ["docker", "load", "-i", load_path]
            res = ctx.run(load_cmd, mutates=True)
            if res.skipped:
                return {"changed": True, "msg": "would load image from " + load_path}
            if res.rc != 0:
                fail("failed to load image from " + load_path + ": " + res.stderr)
            return {"changed": True, "msg": "loaded image from " + load_path}

        fail("unsupported source: " + str(source))

    fail("unsupported state: " + str(state))


def is_image_id(s):
    if not s:
        return False
    if s.startswith("sha256:"):
        return True
    if len(s) < 12:
        return False
    for i in range(len(s)):
        c = s[i]
        if not ((c >= "0" and c <= "9") or (c >= "a" and c <= "f") or (c >= "A" and c <= "F")):
            return False
    return True
