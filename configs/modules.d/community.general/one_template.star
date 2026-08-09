def main(ctx, params):
    # Extract parameters
    api_url = params.get("api_url")
    api_username = params.get("api_username")
    api_password = params.get("api_password")
    template_id = params.get("id")
    name = params.get("name")
    state = params.get("state", "present")
    template_data = params.get("template")
    validate_certs = params.get("validate_certs", True)
    wait_timeout = params.get("wait_timeout", 300)

    # Handle required_if: state=present requires template
    if state == "present" and template_data == None:
        fail("template is required when state is present")

    # Handle mutually_exclusive: id and name cannot be set together
    if template_id != None and name != None:
        fail("id and name are mutually exclusive")
    if template_id == None and name == None:
        fail("one of id or name is required")

    # Authenticate via xmlrpc (we simulate the XMLRPC client with ctx.run)
    # Since Starlark has no XMLRPC library, we implement a minimal mock:
    # In production, this would use ctx.run() to call a helper script.
    # For this translation, we assume a helper binary `one_template_helper` exists.
    # The helper script is out of scope; we model behavior, not real XMLRPC.
    if ctx.check_mode:
        # In check_mode, we cannot call external APIs; we assume idempotent behavior.
        # Per original: check_mode always returns changed=true for existing templates.
        return {
            "changed": True,
            "msg": "check_mode is not fully supported for one_template"
        }

    # Helper binary invocation (mocked): call one_template_helper with args
    def call_helper(args):
        res = ctx.run(["one_template_helper"] + args, mutates=True)
        if res.rc != 0:
            fail("helper failed: " + res.stderr)
        return res.stdout.strip()

    # Fetch template by id/name if exists
    existing = None
    if template_id != None:
        out = call_helper(["--id", str(template_id), "--action", "info"])
        if out != "":
            existing = out
    else:
        out = call_helper(["--name", name, "--action", "info"])
        if out != "":
            existing = out

    if state == "absent":
        if existing == None:
            return {"changed": False, "msg": "template already absent"}
        # Delete
        call_helper(["--id", existing.split("\n")[0].split(":")[1].strip(), "--action", "delete"])
        return {"changed": True, "msg": "template deleted"}

    # state == "present"
    if existing == None:
        # Create new
        if name == None:
            fail("name is required for new template creation")
        # Allocate: template_data contains NAME and content
        call_helper(["--action", "allocate", "--name", name, "--template", template_data])
        # Re-fetch to get ID
        out = call_helper(["--name", name, "--action", "info"])
        if out == "":
            fail("failed to create template")
        return {
            "changed": True,
            "msg": "template created",
            "data": parse_info(out)
        }
    else:
        # Update existing
        template_id_str = existing.split("\n")[0].split(":")[1].strip()
        call_helper(["--action", "update", "--id", template_id_str, "--template", template_data])
        out = call_helper(["--id", template_id_str, "--action", "info"])
        return {
            "changed": True,
            "msg": "template updated",
            "data": parse_info(out)
        }


def parse_info(output):
    # Helper to parse simple key: value lines into dict
    lines = output.split("\n")
    info = {}
    for line in lines:
        if line == "" or line.startswith("---"):
            continue
        idx = line.find(":")
        if idx > 0:
            key = line[:idx].strip()
            val = line[idx+1:].strip()
            if key == "id" or key == "group_id" or key == "owner_id":
                info[key] = int(val) if val.isdigit() else val
            else:
                info[key] = val
    return info
