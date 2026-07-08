def main(ctx, params):
    # Required parameters
    label = params.get("label")
    notification_type = params.get("notification_type")
    details = params.get("details")

    # Validation: label length
    if label == None:
        fail("label is required")
    if len(str(label)) < 1 or len(str(label)) > 255:
        fail("label must be between 1 and 255 characters long")

    # Validation: notification_type
    if notification_type == None:
        fail("notification_type is required")
    if notification_type not in ["webhook", "email", "pagerduty"]:
        fail("notification_type must be one of: webhook, email, pagerduty")

    # Validation: details
    if details == None:
        fail("details is required")

    state = params.get("state", "present")
    if state not in ["present", "absent"]:
        fail("state must be one of: present, absent")

    # Check mode
    check_mode = ctx.check_mode

    # Since this module requires pyrax (Python SDK), which is NOT available
    # in Starlark, we cannot actually execute the Rackspace API calls.
    # Per the contract, if the core functionality cannot be implemented,
    # we must fail with a clear message.
    fail("module rax_mon_notification cannot be implemented in Starlark because it depends on the pyrax SDK, which is only available in Python. Please use the original Ansible Python module in a Python-based Ansible environment.")
