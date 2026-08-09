def main(ctx, params):
    datacenter = params["datacenter"]
    server = params["server"]
    name = params.get("name")
    lan = params.get("lan")
    state = params.get("state", "present")
    subscription_user = params["subscription_user"]
    subscription_password = params["subscription_password"]
    wait = params.get("wait", True)
    wait_timeout = params.get("wait_timeout", 600)

    # Required args checks (mirroring required_if)
    if state == "absent" and name == None:
        fail("name is required when state is absent")
    if state == "present" and lan == None:
        fail("lan is required when state is present")

    # Starlark has no JSON parsing — ProfitBricks API requires JSON I/O
    # Per contract: if core functionality cannot be supported, fail with clear message
    fail("profitbricks_nic requires JSON parsing and HTTP client for ProfitBricks API; the Starlark runtime does not support this module")
