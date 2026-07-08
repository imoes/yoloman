def main(ctx, params):
    src_iso = params["src_iso"]
    dest_iso = params["dest_iso"]
    delete_files = params.get("delete_files", [])
    add_files = params.get("add_files", [])

    # Validate source ISO exists
    if not ctx.file_exists(src_iso):
        fail("ISO file %s does not exist." % src_iso)

    # Validate destination directory exists
    dest_dir = dest_iso
    while len(dest_dir) > 1 and not ctx.file_exists(dest_dir):
        dest_dir = ctx.run(["dirname", dest_iso]).stdout.strip()
        if dest_dir == "/":
            break

    # Check if parent directory exists (simple parent extraction)
    parent = dest_iso.rsplit("/", 1)
    if len(parent) > 1 and parent[0] != "":
        if not ctx.file_exists(parent[0]):
            fail("The dest directory %s does not exist" % parent[0])

    # Validate add_files src exist
    for item in add_files:
        src = item["src_file"]
        if not ctx.file_exists(src):
            fail("The file %s does not exist." % src)

    # Check mode: predict change if any operation is specified
    if len(delete_files) == 0 and len(add_files) == 0:
        return {"changed": False, "msg": "No changes requested"}

    # In check_mode, predict change without executing
    if ctx.check_mode:
        return {"changed": True, "msg": "would customize ISO"}

    # Run iso_customize via command-line wrapper (since pycdlib is not available in Starlark)
    # We rely on the system having the community.general.iso_customize module installed.
    # If not, this will fail.
    res = ctx.run([
        "ansible-playbook", "-i", "localhost,", "-c", "local",
        "-e", "src_iso=%s dest_iso=%s delete_files=%s add_files=%s" % (
            src_iso, dest_iso,
            str(delete_files).replace("'", '"'),
            str(add_files).replace("'", '"')
        ),
        "-e", "_ansible_remote_tmp=/tmp",
        "-e", "_ansible_keep_remote_files=False",
        "-e", "ansible_python_interpreter=auto_silent",
        "-e", "ansible_facts_modules=auto",
        ctx.run(["which", "ansible-playbook"]).stdout.strip()
    ])

    # Alternative: call the module directly if ansible-playbook is too heavy
    # Since pycdlib is not available in Starlark, we cannot implement it directly.
    # This Starlark module delegates to the actual Ansible module via shell command.

    # For true standalone behavior (no Ansible runtime), the module MUST fail.
    fail("The iso_customize module requires pycdlib, which is not available in Starlark. Please use the original Ansible module instead.")
