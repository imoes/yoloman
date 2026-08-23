#!/usr/bin/env bash
# Assemble an APT and a YUM repository from the built packages — a static tree any web server can host,
# GitHub Pages included.
#
# WHY A REPOSITORY AT ALL when the packages are also release assets: `apt install ./file.deb` installs once
# and never tells you about the next version. A repository is what makes `apt upgrade` work, which is the
# whole difference between shipping a file and shipping software.
#
# SIGNING IS OPTIONAL AND ITS ABSENCE IS SAID OUT LOUD. With YOLOMAN_GPG_KEY set, the APT Release is signed
# (InRelease + Release.gpg) and the public key is published in the tree, so a client can verify what it
# installs. Without it the repo is built anyway — but the client has to say [trusted=yes], which disables
# exactly that verification, and the generated instructions state so rather than quietly printing a working
# command line. An unsigned repo that looks signed is worse than no repo.
#
#   scripts/build-repo.sh                      # unsigned, prints what that costs
#   YOLOMAN_GPG_KEY=<keyid> scripts/build-repo.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
VERSION="$(cat VERSION)"
REPO="$ROOT/deploy-artifacts/repo"
KEY="${YOLOMAN_GPG_KEY:-}"
# The public base URL the generated instructions use. Overridable, because a repo hosted anywhere else needs
# the same tree with a different address.
BASE="${YOLOMAN_REPO_URL:-https://imoes.github.io/yoloman}"

need() { [ -f "$1" ] || { echo "missing $1 — run $2 first" >&2; exit 1; }; }
need deploy-artifacts/agent.deb   "scripts/build-agent-deb.sh"
need deploy-artifacts/agent.rpm   "scripts/build-agent-deb.sh"
need deploy-artifacts/bossman.deb "scripts/build-bossman-deb.sh"
need deploy-artifacts/bossman.rpm "scripts/build-bossman-deb.sh"

rm -rf "$REPO"
mkdir -p "$REPO/deb/pool/main" "$REPO/deb/dists/stable/main/binary-amd64" "$REPO/rpm"

# ── APT ─────────────────────────────────────────────────────────────────────────────────────────────────
# The versioned filenames, not agent.deb: a pool holding "the latest" under a fixed name cannot express two
# versions, which is what an upgrade path is made of.
cp "deploy-artifacts/yoloman-agent_${VERSION}_amd64.deb" "$REPO/deb/pool/main/"
cp "deploy-artifacts/yoloman-bossman_${VERSION}_amd64.deb" "$REPO/deb/pool/main/"

echo ">> APT metadata"
( cd "$REPO/deb" && apt-ftparchive packages pool/main > dists/stable/main/binary-amd64/Packages )
gzip -9c "$REPO/deb/dists/stable/main/binary-amd64/Packages" \
  > "$REPO/deb/dists/stable/main/binary-amd64/Packages.gz"
cat > "$REPO/deb/apt-release.conf" <<CONF
APT::FTPArchive::Release::Origin "yoloman";
APT::FTPArchive::Release::Label "YOLO-MANager";
APT::FTPArchive::Release::Suite "stable";
APT::FTPArchive::Release::Codename "stable";
APT::FTPArchive::Release::Architectures "amd64";
APT::FTPArchive::Release::Components "main";
APT::FTPArchive::Release::Description "YOLO-MANager — Bossman and the node agent";
CONF
( cd "$REPO/deb" && apt-ftparchive -c apt-release.conf release dists/stable > dists/stable/Release )
rm "$REPO/deb/apt-release.conf"

if [ -n "$KEY" ]; then
  echo ">> signing the APT release with $KEY"
  gpg --batch --yes --default-key "$KEY" --clearsign -o "$REPO/deb/dists/stable/InRelease" \
      "$REPO/deb/dists/stable/Release"
  gpg --batch --yes --default-key "$KEY" -abs -o "$REPO/deb/dists/stable/Release.gpg" \
      "$REPO/deb/dists/stable/Release"
  gpg --batch --yes --export --armor "$KEY" > "$REPO/yoloman-archive-keyring.asc"
else
  echo ">> NOT signing (YOLOMAN_GPG_KEY unset) — clients will need [trusted=yes]"
fi

# ── YUM ─────────────────────────────────────────────────────────────────────────────────────────────────
cp "deploy-artifacts/yoloman-agent_${VERSION}_amd64.rpm" "$REPO/rpm/"
cp "deploy-artifacts/yoloman-bossman_${VERSION}_amd64.rpm" "$REPO/rpm/"
echo ">> YUM metadata"
# createrepo_c in a container: it is not packaged on every build host, and an EL image has it by definition.
# The proxy is forwarded: without it dnf cannot reach a mirror, and `install -q >/dev/null` hid that so well
# that the next line failed with "createrepo_c: command not found" — an error about the wrong thing.
docker run --rm -v "$REPO/rpm":/repo -e BUILD_UID="$(id -u)" -e BUILD_GID="$(id -g)" \
  -e http_proxy="${http_proxy:-}" -e https_proxy="${https_proxy:-}" -e no_proxy="${no_proxy:-}" \
  almalinux:9 sh -c '
  set -e
  dnf install -y -q createrepo_c
  createrepo_c --quiet /repo
  chown -R "$BUILD_UID:$BUILD_GID" /repo
'
if [ -n "$KEY" ]; then
  gpg --batch --yes --default-key "$KEY" --detach-sign --armor "$REPO/rpm/repodata/repomd.xml"
  gpg --batch --yes --export --armor "$KEY" > "$REPO/rpm/repodata/repomd.xml.key"
fi

# ── the instructions, generated from what was actually built ────────────────────────────────────────────
# Written here rather than hand-maintained in the README: a signed and an unsigned repo need DIFFERENT client
# commands, and a page that shows the signed ones for an unsigned repo teaches a command that fails.
if [ -n "$KEY" ]; then
  APT_LINE="deb [signed-by=/usr/share/keyrings/yoloman-archive-keyring.gpg] $BASE/deb stable main"
  APT_KEY="curl -fsSL $BASE/yoloman-archive-keyring.asc | sudo gpg --dearmor -o /usr/share/keyrings/yoloman-archive-keyring.gpg"
  RPM_GPG="gpgcheck=1
gpgkey=$BASE/rpm/repodata/repomd.xml.key"
else
  APT_LINE="deb [trusted=yes] $BASE/deb stable main"
  APT_KEY="# unsigned repository — nothing to import, and nothing verified either"
  RPM_GPG="gpgcheck=0"
fi

cat > "$REPO/index.html" <<HTML
<!doctype html>
<meta charset="utf-8">
<title>YOLO-MANager package repository</title>
<style>body{font:15px/1.6 system-ui,sans-serif;max-width:52rem;margin:3rem auto;padding:0 1rem}
pre{background:#f5f5f5;padding:.8rem;overflow-x:auto;border-radius:6px}code{font-size:.92em}
.warn{background:#fff4f4;border-left:3px solid #d33;padding:.6rem .8rem}</style>
<h1>YOLO-MANager package repository</h1>
<p>Version <strong>$VERSION</strong>. Docker Compose remains the primary deployment; these packages are for
hosts where a container runtime is not wanted. <code>yoloman-agent</code> is the node agent,
<code>yoloman-bossman</code> the fleet controller.</p>
$( [ -n "$KEY" ] || echo '<p class="warn"><strong>This repository is not signed.</strong> The commands below
therefore disable signature checking (<code>trusted=yes</code> / <code>gpgcheck=0</code>): your package
manager will install whatever this address serves, without verifying who built it. Fine on a trusted network
for a trial; not what you want in production.</p>' )
<h2>Debian / Ubuntu</h2>
<pre>$APT_KEY
echo "$APT_LINE" | sudo tee /etc/apt/sources.list.d/yoloman.list
sudo apt update
sudo apt install yoloman-agent      # a managed node
sudo apt install yoloman-bossman    # the controller</pre>
<h2>RHEL / AlmaLinux / Rocky / Fedora</h2>
<pre>sudo tee /etc/yum.repos.d/yoloman.repo &lt;&lt;'REPO'
[yoloman]
name=YOLO-MANager
baseurl=$BASE/rpm
enabled=1
$RPM_GPG
REPO
sudo dnf install yoloman-agent
sudo dnf install yoloman-bossman</pre>
<h2>Bossman needs a database</h2>
<p>PostgreSQL with the <strong>timescaledb</strong> and <strong>pgvector</strong> extensions. The package
does not install it, and the postinst prints the four steps; the full walk-through is the Quick start in the
<a href="https://github.com/imoes/yoloman#quick-start">README</a>.</p>
HTML

find "$REPO" -type f | sed "s|$REPO|repo|" | sort
echo
echo ">> $REPO"
[ -n "$KEY" ] && echo ">> signed with $KEY" || echo ">> UNSIGNED — see the warning on the generated page"
