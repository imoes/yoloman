def main(ctx, params):
    api_url = params.get("api_url")
    api_username = params.get("api_username")
    api_password = params.get("api_password")
    image_id = params.get("id")
    image_name = params.get("name")
    state = params.get("state", "present")
    enabled = params.get("enabled")
    new_name = params.get("new_name")

    # Connection info with env fallback
    if api_url == None:
        api_url = ctx.facts().get("one_url", "")
    if api_username == None:
        api_username = ctx.facts().get("one_username", "")
    if api_password == None:
        api_password = ctx.facts().get("one_password", "")

    if api_url == "" or api_username == "" or api_password == "":
        fail("One or more connection parameters (api_url, api_username, api_password) were not specified")

    # State validation
    if state not in ["present", "absent", "cloned", "renamed"]:
        fail("Unsupported state: " + state)
    if state == "renamed" and image_id == None:
        fail("Option 'id' is required when the state is 'renamed'")

    # Fetch image list via oneimage list
    res = ctx.run(["oneimage", "list", "-x"], mutates=False)
    if res.rc != 0:
        fail("Failed to fetch image list: " + res.stderr)

    xml = res.stdout
    images = []
    # Basic XML parser for <IMAGE> blocks
    parts = xml.split("<IMAGE>")
    for part in parts[1:]:
        end = part.find("</IMAGE>")
        if end == -1:
            continue
        block = part[:end]
        def get_tag(tag, block=block):
            start = block.find("<" + tag + ">")
            if start == -1:
                return ""
            start += len(tag) + 2
            end_tag = block.find("</" + tag + ">")
            if end_tag == -1:
                return ""
            return block[start:end_tag].strip()
        img = {
            "ID": int(get_tag("ID")) if get_tag("ID") != "" else 0,
            "NAME": get_tag("NAME"),
            "STATE": get_tag("STATE"),
            "RUNNING_VMS": int(get_tag("RUNNING_VMS")) if get_tag("RUNNING_VMS") != "" else 0,
            "UNAME": get_tag("UNAME"),
            "UID": int(get_tag("UID")) if get_tag("UID") != "" else 0,
            "GNAME": get_tag("GNAME"),
            "GID": int(get_tag("GID")) if get_tag("GID") != "" else 0,
        }
        images.append(img)

    def get_image_by_id(img_id):
        for img in images:
            if img["ID"] == img_id:
                return img
        return None

    def get_image_by_name(name):
        for img in images:
            if img["NAME"] == name:
                return img
        return None

    image = None
    if image_id != None:
        image = get_image_by_id(image_id)
        if image == None and state != "absent":
            fail("There is no image with id=" + str(image_id))
    else:
        image = get_image_by_name(image_name)
        if image == None and state != "absent":
            fail("There is no image with name=" + str(image_name))

    def image_info(img):
        states = ["INIT", "READY", "USED", "DISABLED", "LOCKED", "ERROR", "CLONE", "DELETE", "USED_PERS", "LOCKED_USED", "LOCKED_USED_PERS"]
        state_int = int(img["STATE"]) if img["STATE"] != "" else 0
        state_str = states[state_int] if (0 <= state_int and state_int < len(states)) else "UNKNOWN"
        return {
            "id": img["ID"],
            "name": img["NAME"],
            "state": state_str,
            "running_vms": img["RUNNING_VMS"],
            "used": img["RUNNING_VMS"] > 0,
            "owner_name": img["UNAME"],
            "owner_id": img["UID"],
            "group_name": img["GNAME"],
            "group_id": img["GID"],
        }

    if state == "absent":
        if image == None:
            return {"changed": False, "msg": "Image already absent"}
        if image["RUNNING_VMS"] > 0:
            fail("Cannot delete image. There are " + str(image["RUNNING_VMS"]) + " VMs using it.")
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete image " + image["NAME"]}
        res = ctx.run(["oneimage", "delete", str(image["ID"])], mutates=True)
        if res.rc != 0:
            fail("Failed to delete image: " + res.stderr)
        return {"changed": True, "msg": "deleted image " + image["NAME"], "data": image_info(image)}

    if image == None:
        fail("Image not found")

    result = {"changed": False, "msg": "", "data": image_info(image)}

    # Handle enabled
    if enabled != None:
        state_int = int(image["STATE"]) if image["STATE"] != "" else 0
        states = ["INIT", "READY", "USED", "DISABLED", "LOCKED", "ERROR", "CLONE", "DELETE", "USED_PERS", "LOCKED_USED", "LOCKED_USED_PERS"]
        state_str = states[state_int] if (0 <= state_int and state_int < len(states)) else "UNKNOWN"
        allowed_states = ["READY", "DISABLED", "ERROR"]
        if state_str not in allowed_states:
            fail("Cannot " + ("enable" if enabled else "disable") + " " + state_str + " image")
        need_change = (enabled and state_str != "READY") or (not enabled and state_str != "DISABLED")
        if not need_change:
            result["msg"] = image["NAME"] + " already in desired state"
        else:
            if ctx.check_mode:
                result["changed"] = True
                result["msg"] = "would " + ("enable" if enabled else "disable") + " " + image["NAME"]
                return result
            res = ctx.run(["oneimage", "enable", str(image["ID"]), "true" if enabled else "false"], mutates=True)
            if res.rc != 0:
                fail("Failed to " + ("enable" if enabled else "disable") + " image: " + res.stderr)
            result["changed"] = True
            result["msg"] = ("enabled" if enabled else "disabled") + " " + image["NAME"]

    # Handle state actions
    if state == "cloned":
        if image["STATE"] == "3":  # DISABLED
            fail("Cannot clone DISABLED image")
        if new_name == None:
            new_name = "Copy of " + image["NAME"]
        dup = get_image_by_name(new_name)
        if dup != None:
            result["msg"] = "clone already exists as " + new_name
            result["data"] = image_info(dup)
            return result
        if ctx.check_mode:
            result["changed"] = True
            result["msg"] = "would clone " + image["NAME"] + " to " + new_name
            return result
        res = ctx.run(["oneimage", "clone", str(image["ID"]), new_name], mutates=True)
        if res.rc != 0:
            fail("Failed to clone image: " + res.stderr)
        clone_img = get_image_by_name(new_name)
        if clone_img == None:
            fail("Clone image not found after clone operation")
        result["changed"] = True
        result["msg"] = "cloned " + image["NAME"] + " to " + new_name
        result["data"] = image_info(clone_img)

    elif state == "renamed":
        if new_name == None:
            fail("Option 'new_name' has to be specified when the state is 'renamed'")
        if new_name == image["NAME"]:
            result["msg"] = "name already correct"
            return result
        dup = get_image_by_name(new_name)
        if dup != None:
            fail("Name '" + new_name + "' is already taken by IMAGE with id=" + str(dup["ID"]))
        if ctx.check_mode:
            result["changed"] = True
            result["msg"] = "would rename " + image["NAME"] + " to " + new_name
            return result
        res = ctx.run(["oneimage", "rename", str(image["ID"]), new_name], mutates=True)
        if res.rc != 0:
            fail("Failed to rename image: " + res.stderr)
        image["NAME"] = new_name
        result["changed"] = True
        result["msg"] = "renamed " + image["NAME"] + " to " + new_name
        result["data"] = image_info(image)

    else:
        result["msg"] = "image already present"

    return result
