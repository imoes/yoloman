def main(ctx, params):
    api_key = params.get("api_key")
    apps = params["apps"]
    state = params.get("state", "present")
    suppress_invitation = params.get("suppress_invitation", False)
    user = params["user"]

    # Validate required params
    if not user:
        fail("user is required")
    if not apps:
        fail("apps is required")

    def list_collaborators(app_name):
        res = ctx.run(
            ["heroku", "collaborators", "--app", app_name, "--json"],
            mutates=False
        )
        if res.rc != 0:
            fail("failed to list collaborators for app " + app_name + ": " + res.stderr)
        output = res.stdout.strip()
        if not output or len(output) < 2:
            return []
        # Strip outer brackets
        content = output[1:len(output)-1]
        if not content:
            return []
        collaborators = []
        # Split by },{ pattern
        items = content.split("},{")
        for item in items:
            item = item.strip()
            # Find email: value
            email_start = item.find('"email"')
            if email_start == -1:
                continue
            colon = item.find(':', email_start)
            if colon == -1:
                continue
            quote_start = item.find('"', colon)
            if quote_start == -1:
                continue
            quote_end = item.find('"', quote_start + 1)
            if quote_end == -1:
                continue
            email = item[quote_start + 1:quote_end]
            collaborators.append(email)
        return collaborators

    def add_collaborator(app_name, user, silent):
        silent_flag = []
        if silent:
            silent_flag = ["--silent"]
        res = ctx.run(
            ["heroku", "collaborators:add", user] + silent_flag + ["--app", app_name],
            mutates=True
        )
        if res.skipped:
            return True
        if res.rc != 0:
            fail("failed to add collaborator " + user + " to app " + app_name + ": " + res.stderr)
        return False

    def remove_collaborator(app_name, user):
        res = ctx.run(
            ["heroku", "collaborators:remove", user, "--app", app_name, "--confirm", app_name],
            mutates=True
        )
        if res.skipped:
            return True
        if res.rc != 0:
            fail("failed to remove collaborator " + user + " from app " + app_name + ": " + res.stderr)
        return False

    affected_apps = []

    if ctx.check_mode:
        for app in apps:
            # Verify app exists
            res = ctx.run(["heroku", "apps:info", "--app", app], mutates=False)
            if res.rc != 0:
                fail("App '" + app + "' does not exist")

            collaborators = list_collaborators(app)
            if state == "present" and user not in collaborators:
                affected_apps.append(app)
            elif state == "absent" and user in collaborators:
                affected_apps.append(app)

        if len(affected_apps) > 0:
            return {"changed": True, "msg": str(affected_apps)}
        return {"changed": False, "msg": "All apps already in desired state"}

    # Actual mode
    for app in apps:
        # Verify app exists
        res = ctx.run(["heroku", "apps:info", "--app", app], mutates=False)
        if res.rc != 0:
            fail("App '" + app + "' does not exist")

        collaborators = list_collaborators(app)

        if state == "present":
            if user in collaborators:
                continue
            if add_collaborator(app, user, suppress_invitation):
                affected_apps.append(app)
            else:
                affected_apps.append(app)

        elif state == "absent":
            if user not in collaborators:
                continue
            if remove_collaborator(app, user):
                affected_apps.append(app)
            else:
                affected_apps.append(app)

    if len(affected_apps) > 0:
        return {"changed": True, "msg": str(affected_apps)}
    return {"changed": False, "msg": "No changes required"}
