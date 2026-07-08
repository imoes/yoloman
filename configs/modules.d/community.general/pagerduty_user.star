def main(ctx, params):
    access_token = params["access_token"]
    pd_user = params["pd_user"]
    pd_email = params["pd_email"]
    state = params.get("state", "present")
    pd_role = params.get("pd_role", "responder")
    pd_teams = params.get("pd_teams")

    # Map PagerDuty UI roles to API role names
    role_map = {
        "global_admin": "admin",
        "manager": "user",
        "responder": "limited_user",
        "observer": "observer",
        "stakeholder": "read_only_user",
        "limited_stakeholder": "read_only_limited_user",
        "restricted_access": "restricted_access"
    }
    if pd_role not in role_map:
        fail("unsupported pd_role: " + pd_role)
    api_role = role_map[pd_role]

    # Validate required pd_teams for present state
    if state == "present" and pd_teams == None:
        fail("pd_teams is required when state=present")

    # Build auth header
    auth_header = "-H Authorization: Token token=" + access_token
    accept_header = "-H Accept: application/vnd.pagerduty+json;version=2"

    # Helper to make API calls using curl
    def api_call(method, endpoint, json_data=None):
        url = "https://api.pagerduty.com" + endpoint
        cmd = ["curl", "-s", "-X", method, accept_header, auth_header]
        if json_data != None:
            cmd.extend(["-H", "Content-Type: application/json", "-d", json_data])
        cmd.append(url)
        res = ctx.run(cmd)
        if res.rc != 0:
            fail("API call failed: " + res.stderr)
        return res.stdout.strip(), res.rc

    # Find user by email
    def find_user_by_email(email):
        stdout, rc = api_call("GET", "/users")
        if rc != 200:
            return None
        # Parse JSON using simple string processing
        if "users" not in stdout:
            return None
        users_str = stdout
        # Extract user entries
        start_idx = users_str.find('"users"')
        if start_idx == -1:
            return None
        start_bracket = users_str.find('[', start_idx)
        end_bracket = users_str.rfind(']')
        if start_bracket == -1 or end_bracket == -1:
            return None
        users_array_str = users_str[start_bracket:end_bracket + 1]
        
        # Simple JSON object parser for user email/id
        idx = 0
        while True:
            email_idx = users_array_str.find('"email"', idx)
            if email_idx == -1:
                break
            colon_idx = users_array_str.find(':', email_idx)
            if colon_idx == -1:
                break
            # Extract email string value
            quote1 = users_array_str.find('"', colon_idx)
            if quote1 == -1:
                break
            quote2 = users_array_str.find('"', quote1 + 1)
            if quote2 == -1:
                break
            user_email = users_array_str[quote1 + 1:quote2]
            if user_email == email:
                # Now find id for this user
                user_start = users_array_str.rfind('{', 0, email_idx - 100)
                if user_start == -1:
                    user_start = users_array_str.rfind('{', 0, email_idx)
                if user_start != -1:
                    # Find id field within this user object
                    id_idx = users_array_str.find('"id"', user_start)
                    if id_idx != -1:
                        colon = users_array_str.find(':', id_idx)
                        if colon != -1:
                            q1 = users_array_str.find('"', colon)
                            q2 = users_array_str.find('"', q1 + 1)
                            if q2 != -1:
                                return users_array_str[q1 + 1:q2]
            idx = end_bracket
        return None

    # Get user's existing teams
    def get_user_teams(user_id):
        teams = []
        stdout, rc = api_call("GET", "/users/" + user_id + "/teams")
        if rc != 200:
            return teams
        if "teams" not in stdout:
            return teams
        # Parse team names
        idx = 0
        while True:
            name_idx = stdout.find('"name"', idx)
            if name_idx == -1:
                break
            colon_idx = stdout.find(':', name_idx)
            if colon_idx == -1:
                break
            quote1 = stdout.find('"', colon_idx)
            if quote1 == -1:
                break
            quote2 = stdout.find('"', quote1 + 1)
            if quote2 == -1:
                break
            team_name = stdout[quote1 + 1:quote2]
            teams.append(team_name)
            idx = quote2 + 1
        return teams

    # Create user
    def create_user(name, email, role):
        payload = '{"user": {"name": "' + name + '", "email": "' + email + '", "type": "user", "role": "' + role + '"}}'
        stdout, rc = api_call("POST", "/users", payload)
        return rc == 201

    # Delete user
    def delete_user(user_id):
        stdout, rc = api_call("DELETE", "/users/" + user_id)
        return rc == 204

    # Add user to team
    def add_user_to_team(team_id, user_id, role):
        payload = '{"user": {"role": "' + role + '"}}'
        stdout, rc = api_call("PUT", "/teams/" + team_id + "/users/" + user_id, payload)
        return rc == 200

    # Find team ID by name
    def find_team_id(team_name):
        stdout, rc = api_call("GET", "/teams")
        if rc != 200:
            return None
        # Parse teams array to find matching name
        idx = 0
        while True:
            name_idx = stdout.find('"name"', idx)
            if name_idx == -1:
                break
            colon_idx = stdout.find(':', name_idx)
            if colon_idx == -1:
                break
            quote1 = stdout.find('"', colon_idx)
            if quote1 == -1:
                break
            quote2 = stdout.find('"', quote1 + 1)
            if quote2 == -1:
                break
            name = stdout[quote1 + 1:quote2]
            if name == team_name:
                # Find id for this team
                start = stdout.rfind('{', 0, name_idx - 100)
                if start == -1:
                    start = stdout.rfind('{', 0, name_idx)
                if start != -1:
                    id_idx = stdout.find('"id"', start)
                    if id_idx != -1:
                        colon = stdout.find(':', id_idx)
                        if colon != -1:
                            q1 = stdout.find('"', colon)
                            q2 = stdout.find('"', q1 + 1)
                            if q2 != -1:
                                return stdout[q1 + 1:q2]
            idx = quote2 + 1
        return None

    # Main logic
    user_id = find_user_by_email(pd_email)

    if state == "present":
        if user_id != None:
            # User exists - check teams
            current_teams = get_user_teams(user_id)
            desired_teams = pd_teams if pd_teams != None else []
            teams_changed = False
            for t in desired_teams:
                if t not in current_teams:
                    teams_changed = True
                    break
            if not teams_changed:
                return {"changed": False, "msg": "User " + pd_user + " already exists and is in correct teams."}
            # Add to missing teams
            if ctx.check_mode:
                return {"changed": True, "msg": "would add user to missing teams."}
            for t in desired_teams:
                team_id = find_team_id(t)
                if team_id != None:
                    add_user_to_team(team_id, user_id, api_role)
            return {"changed": True, "msg": "User " + pd_user + " updated with correct teams."}
        else:
            # Create user
            if ctx.check_mode:
                return {"changed": True, "msg": "would create user " + pd_user + " and add to teams."}
            created = create_user(pd_user, pd_email, api_role)
            if not created:
                fail("Failed to create user " + pd_user)
            user_id = find_user_by_email(pd_email)
            if user_id == None:
                fail("Failed to retrieve created user ID")
            if pd_teams != None:
                for t in pd_teams:
                    team_id = find_team_id(t)
                    if team_id != None:
                        add_user_to_team(team_id, user_id, api_role)
            return {"changed": True, "msg": "User " + pd_user + " created and added to teams."}

    elif state == "absent":
        if user_id == None:
            return {"changed": False, "msg": "User " + pd_user + " not found."}
        if ctx.check_mode:
            return {"changed": True, "msg": "would delete user " + pd_user}
        deleted = delete_user(user_id)
        if not deleted:
            fail("Failed to delete user " + pd_user)
        return {"changed": True, "msg": "User " + pd_user + " deleted."}

    fail("Unsupported state: " + state)
