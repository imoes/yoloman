def main(ctx, params):
    clients = params.get("clients", ["pip"])
    packages = {}

    for pip in clients:
        basename = pip.rsplit("/", 1)[-1] if "/" in pip else pip
        if not basename.startswith("pip"):
            continue

        res = ctx.run([pip, "--version"], mutates=False)
        if res.rc != 0:
            continue

        res = ctx.run([pip, "list", "--format=json"], mutates=False)
        if res.rc != 0:
            continue

        lines = res.stdout.strip().splitlines()
        pkgs_list = []
        i = 0
        while i < len(lines):
            line = lines[i].strip()
            if line == "[" or line == "":
                i += 1
                continue
            if line == "]":
                break
            if line.startswith("{"):
                obj_lines = [line]
                depth = line.count("{") - line.count("}")
                i += 1
                while i < len(lines) and depth > 0:
                    obj_lines.append(lines[i])
                    depth += lines[i].count("{") - lines[i].count("}")
                    i += 1
                obj_str = "".join(obj_lines).strip()

                # Extract name
                name_key = '"name"'
                name_start = obj_str.find(name_key)
                if name_start == -1:
                    name_key = "'name'"
                    name_start = obj_str.find(name_key)
                if name_start == -1:
                    i += 1
                    continue
                name_start = name_start + len(name_key)
                while name_start < len(obj_str) and obj_str[name_start] in " \t:\"'":
                    name_start += 1
                name_end = name_start
                if name_start < len(obj_str) and obj_str[name_start] in "\"'":
                    quote = obj_str[name_start]
                    name_end = name_start + 1
                    while name_end < len(obj_str) and obj_str[name_end] != quote:
                        name_end += 1
                    name = obj_str[name_start + 1:name_end]
                else:
                    while name_end < len(obj_str) and obj_str[name_end] not in ",} \t":
                        name_end += 1
                    name = obj_str[name_start:name_end].strip()

                # Extract version
                ver_key = '"version"'
                ver_start = obj_str.find(ver_key)
                if ver_start == -1:
                    ver_key = "'version'"
                    ver_start = obj_str.find(ver_key)
                if ver_start == -1:
                    ver = ""
                else:
                    ver_start = ver_start + len(ver_key)
                    while ver_start < len(obj_str) and obj_str[ver_start] in " \t:\"'":
                        ver_start += 1
                    ver_end = ver_start
                    if ver_start < len(obj_str) and obj_str[ver_start] in "\"'":
                        quote = obj_str[ver_start]
                        ver_end = ver_start + 1
                        while ver_end < len(obj_str) and obj_str[ver_end] != quote:
                            ver_end += 1
                        ver = obj_str[ver_start + 1:ver_end]
                    else:
                        while ver_end < len(obj_str) and obj_str[ver_end] not in ",} \t":
                            ver_end += 1
                        ver = obj_str[ver_start:ver_end].strip()

                pkgs_list.append({"name": name, "source": pip, "version": ver})
            i += 1

        if pkgs_list:
            packages[pip] = pkgs_list

    if not packages:
        fail("Unable to use any of the supplied pip clients: " + str(clients))

    return {"changed": False, "msg": "collected package info", "data": {"packages": packages}}
