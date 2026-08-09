def main(ctx, params):
    label = params.get("label")
    entity_id = params.get("entity_id")
    check_id = params.get("check_id")
    notification_plan_id = params.get("notification_plan_id")
    criteria = params.get("criteria")
    disabled = params.get("disabled", False)
    metadata = params.get("metadata")
    state = params.get("state", "present")

    # Basic validation
    if label == None or len(label) < 1 or len(label) > 255:
        fail("label must be between 1 and 255 characters long")

    if criteria != None and (len(criteria) < 1 or len(criteria) > 16384):
        fail("criteria must be between 1 and 16384 characters long")

    # Check for pyrax availability via env or facts
    facts = ctx.facts()
    os_family = facts.get("os_family", "")
    # We cannot rely on pyrax availability, so this module must fail if not installed
    # Since there's no way to detect installed modules, we assume pyrax is unavailable
    # and fail with an appropriate message as per original module behavior.
    fail("pyrax is required for this module")

    # Note: The actual pyrax integration is not possible in Starlark.
    # This module cannot be implemented without access to the pyrax library,
    # which requires Python runtime. This is a placeholder implementation
    # that demonstrates the structure and fails with a clear message.
