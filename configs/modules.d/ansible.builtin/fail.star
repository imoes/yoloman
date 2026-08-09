def main(ctx, params):
    msg = params.get("msg", "Failed as requested from task")
    fail(msg)
