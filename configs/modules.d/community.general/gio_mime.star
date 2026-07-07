def main(ctx, params):
    mime_type = params["mime_type"]
    handler = params["handler"]

    # Read-only probe: get current handler for the mime type
    res = ctx.run(["gio", "mime", mime_type], mutates=False)
    if res.rc != 0:
        fail("failed to get current mime handler for '" + mime_type + "': " + res.stderr)

    current_handler = res.stdout.strip() if res.stdout else ""

    # Idempotency check
    if current_handler == handler:
        return {
            "changed": False,
            "msg": "handler for '" + mime_type + "' is already '" + handler + "'"
        }

    # In check_mode, report what would happen
    if ctx.check_mode:
        return {
            "changed": True,
            "msg": "would set handler '" + handler + "' for mime type '" + mime_type + "'"
        }

    # Perform the change
    set_res = ctx.run(["gio", "mime", mime_type, handler], mutates=True)
    if set_res.skipped:
        # Should not happen (check_mode_skip=True in original), but handle safely
        return {
            "changed": True,
            "msg": "would set handler '" + handler + "' for mime type '" + mime_type + "'"
        }
    if set_res.rc != 0:
        fail("failed to set handler '" + handler + "' for mime type '" + mime_type + "': " + set_res.stderr)

    return {
        "changed": True,
        "msg": "set handler '" + handler + "' for mime type '" + mime_type + "'",
        "data": {
            "handler": handler,
            "stdout": set_res.stdout,
            "stderr": set_res.stderr
        }
    }
