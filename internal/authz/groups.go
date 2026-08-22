package authz

// Group resolution, with NO build tag — deliberately.
//
// This lived in pam.go, which is `//go:build cgo`, so the CGO-free build had no way to resolve a user's
// groups at all. That was invisible while only PAM used it; the static build's unix_chkpwd login (chkpwd.go)
// needs the same answer, and needs it in exactly the build where PAM is absent. Group membership has nothing
// to do with how a password was checked, so it does not belong behind that tag.

import "os/user"

// systemGroupsForUser resolves username's group names via the real system user/group database.
func systemGroupsForUser(username string) ([]string, error) {
	u, err := user.Lookup(username)
	if err != nil {
		return nil, err
	}
	gids, err := u.GroupIds()
	if err != nil {
		return nil, err
	}
	groups := make([]string, 0, len(gids))
	for _, gid := range gids {
		g, err := user.LookupGroupId(gid)
		if err != nil {
			continue // skip unresolvable gids rather than failing the whole lookup
		}
		groups = append(groups, g.Name)
	}
	return groups, nil
}
