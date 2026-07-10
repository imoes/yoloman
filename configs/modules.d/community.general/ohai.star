def main(ctx, params):
    res = ctx.run(["/usr/bin/env", "ohai"])
    if res.rc != 0:
        fail("ohai failed: " + res.stderr)
    # Starlark has no JSON parser; use simple heuristic to detect JSON start
    stripped = res.stdout.strip()
    if not stripped.startswith("{") and not stripped.startswith("["):
        fail("ohai output is not valid JSON: missing opening brace or bracket")
    return {"changed": False, "msg": "ohai data retrieved", "data": {}}
