def main(ctx, params):
    name = params["name"]
    tag = params.get("tag", "latest")
    repositories = params["repository"]
    existing_images = params.get("existing_images", "overwrite")

    # Extract repo:tag from name if present
    if ":" in name and "@" not in name:
        parts = name.rsplit(":", 1)
        if len(parts) == 2 and not parts[1].startswith("@"):
            name = parts[0]
            tag = parts[1]

    # Validate tag
    def is_valid_tag(t):
        if t == "":
            return True
        for c in t:
            if not (33 <= ord(c) and ord(c) <= 126) or c == ":" or c == "*":
                return False
        return True

    if not is_valid_tag(tag):
        fail('"{0}" is not a valid docker tag'.format(tag))

    # Parse repositories and validate
    parsed_repos = []
    for i, repo in enumerate(repositories):
        if "@" in repo:
            fail("repository[%d] must not have a digest; got: %s" % (i + 1, repo))
        if ":" in repo:
            parts = repo.rsplit(":", 1)
            repo_name, repo_tag = parts[0], parts[1]
        else:
            repo_name, repo_tag = repo, tag
        if repo_name == "":
            fail("repository[%d] must not be empty" % (i + 1))
        parsed_repos.append((repo_name, repo_tag))

    # Get image id via docker images
    def find_image(name, tag):
        res = ctx.run([
            "docker", "images", "--format", "{{.ID}}",
            "{0}:{1}".format(name, tag)
        ], mutates=False)
        if res.rc == 0 and res.stdout.strip():
            return res.stdout.strip().splitlines()[0]
        return None

    # Find source image
    image_id = find_image(name, tag)
    if image_id == None:
        fail("Cannot find image {0}:{1}".format(name, tag))

    # Tag each repository
    tagged_images = []
    actions = []
    changed = False

    for repo_name, repo_tag in parsed_repos:
        target_id = find_image(repo_name, repo_tag)
        already_tagged = target_id == image_id

        if already_tagged:
            actions.append("Not tagged image {0} as {1}:{2}: target image already exists and is as expected".format(
                image_id, repo_name, repo_tag
            ))
            tagged_images.append("{0}:{1}".format(repo_name, repo_tag))
            continue

        if existing_images == "keep" and target_id != None:
            actions.append("Not tagged image {0} as {1}:{2}: target image already exists and is not as expected, but kept".format(
                image_id, repo_name, repo_tag
            ))
            tagged_images.append("{0}:{1}".format(repo_name, repo_tag))
            continue

        # Perform tagging
        if ctx.check_mode:
            changed = True
            actions.append("Would tag image {0} as {1}:{2}".format(image_id, repo_name, repo_tag))
            tagged_images.append("{0}:{1}".format(repo_name, repo_tag))
            continue

        res = ctx.run([
            "docker", "tag", image_id, "{0}:{1}".format(repo_name, repo_tag)
        ], mutates=True)

        if res.rc != 0:
            fail("Error: failed to tag image as {0}:{1} - {2}".format(
                repo_name, repo_tag, res.stderr.strip()
            ))

        changed = True
        actions.append("Tagged image {0} as {1}:{2}: target image existed and was replaced".format(
            image_id, repo_name, repo_tag
        ))
        tagged_images.append("{0}:{1}".format(repo_name, repo_tag))

    return {
        "changed": changed,
        "msg": "Done" if not changed else "Tagged images",
        "data": {
            "image": {"Id": image_id},
            "tagged_images": tagged_images,
            "actions": actions
        }
    }
