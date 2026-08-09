def main(ctx, params):
    # Check at least one prune target is enabled
    targets = [
        params.get("containers"),
        params.get("images"),
        params.get("networks"),
        params.get("volumes"),
        params.get("builder_cache"),
    ]
    if not any(targets):
        fail("At least one of containers, images, networks, volumes, or builder_cache must be true")

    result = {}
    changed = False

    def build_filters(filters_dict):
        if not filters_dict:
            return []
        out = []
        for k, v in filters_dict.items():
            if type(v) == bool:
                out.append(k + "=" + ("true" if v else "false"))
            else:
                out.append(k + "=" + str(v))
        return out

    def prune_api(path, filters_dict):
        # Build filter JSON array: {"name": ["value1", "value2"], ...}
        filter_parts = []
        if filters_dict:
            for k, v in filters_dict.items():
                if type(v) == bool:
                    filter_parts.append('"' + k + '": ["' + ("true" if v else "false") + '"]')
                else:
                    filter_parts.append('"' + k + '": ["' + str(v) + '"]')
        filters_json_body = "{" + ", ".join(filter_parts) + "}"

        if filters_dict:
            cmd = [
                "curl", "-s", "-X", "POST",
                "-H", "Content-Type: application/json",
                "--unix-socket", "/var/run/docker.sock",
                "http://localhost" + path,
                "-d", '{"filters": ' + filters_json_body + '}'
            ]
        else:
            cmd = [
                "curl", "-s", "-X", "POST",
                "-H", "Content-Type: application/json",
                "--unix-socket", "/var/run/docker.sock",
                "http://localhost" + path,
                "-d", "{}"
            ]

        res = ctx.run(cmd, mutates=True)
        if res.skipped:
            return None
        if res.rc != 0:
            fail("docker prune API call failed: " + res.stderr)

        output = res.stdout.strip()
        reclaimed = 0
        ids_list = []

        # Extract SpaceReclaimed
        key = '"SpaceReclaimed":'
        idx = output.find(key)
        if idx >= 0:
            val_start = idx + len(key)
            val_end = val_start
            while val_end < len(output) and output[val_end] in "0123456789":
                val_end += 1
            if val_end > val_start:
                reclaimed = int(output[val_start:val_end])

        # Extract deleted IDs lists
        for key_name in ['"ContainersDeleted":', '"ImagesDeleted":', '"NetworksDeleted":', '"VolumesDeleted":']:
            idx = output.find(key_name)
            if idx >= 0:
                list_start = output.find('[', idx)
                if list_start >= 0:
                    list_end = output.find(']', list_start)
                    if list_end > list_start:
                        raw = output[list_start+1:list_end].strip()
                        if raw:
                            parts = raw.split('"')
                            for p in parts:
                                if len(p) == 64:
                                    is_hex = True
                                    for c in p.lower():
                                        if c not in "0123456789abcdef":
                                            is_hex = False
                                            break
                                    if is_hex:
                                        ids_list.append(p)

        return {"reclaimed": reclaimed, "ids": ids_list}

    # Containers prune
    if params.get("containers"):
        res = prune_api("/containers/prune", params.get("containers_filters"))
        if res == None:
            changed = True
            result["containers"] = []
            result["containers_space_reclaimed"] = 0
        else:
            result["containers"] = res["ids"]
            result["containers_space_reclaimed"] = res["reclaimed"]
            if res["ids"] or res["reclaimed"] > 0:
                changed = True

    # Images prune
    if params.get("images"):
        res = prune_api("/images/prune", params.get("images_filters"))
        if res == None:
            changed = True
            result["images"] = []
            result["images_space_reclaimed"] = 0
        else:
            result["images"] = res["ids"]
            result["images_space_reclaimed"] = res["reclaimed"]
            if res["ids"] or res["reclaimed"] > 0:
                changed = True

    # Networks prune
    if params.get("networks"):
        res = prune_api("/networks/prune", params.get("networks_filters"))
        if res == None:
            changed = True
            result["networks"] = []
        else:
            result["networks"] = res["ids"]
            if res["ids"]:
                changed = True

    # Volumes prune
    if params.get("volumes"):
        res = prune_api("/volumes/prune", params.get("volumes_filters"))
        if res == None:
            changed = True
            result["volumes"] = []
            result["volumes_space_reclaimed"] = 0
        else:
            result["volumes"] = res["ids"]
            result["volumes_space_reclaimed"] = res["reclaimed"]
            if res["ids"] or res["reclaimed"] > 0:
                changed = True

    # Builder cache prune
    if params.get("builder_cache"):
        res = prune_api("/build/prune", None)
        if res == None:
            changed = True
            result["builder_cache_space_reclaimed"] = 0
        else:
            result["builder_cache_space_reclaimed"] = res["reclaimed"]
            if res["reclaimed"] > 0:
                changed = True

    result["changed"] = changed
    result["msg"] = "Prune completed"
    return result
