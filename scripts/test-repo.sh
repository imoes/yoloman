#!/usr/bin/env bash
# Install FROM the repository, on both families. Building metadata and serving it are two different claims:
# apt-ftparchive happily produces a Packages file whose paths do not resolve, and createrepo_c a repodata
# that dnf rejects. The only proof is `apt install yoloman-agent` off a real HTTP server.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD/deploy-artifacts/repo"
[ -d "$REPO/deb/dists" ] || { echo "no repo — run scripts/build-repo.sh first"; exit 1; }

NET=yoloman-repotest
WEB=yoloman-repotest-web
cleanup() { docker rm -f "$WEB" >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup
docker network create "$NET" >/dev/null
docker run -d --name "$WEB" --network "$NET" -v "$REPO":/usr/share/nginx/html:ro nginx:alpine >/dev/null
for _ in $(seq 1 30); do
  docker run --rm --network "$NET" nginx:alpine sh -c "wget -q -O- http://$WEB/index.html >/dev/null" && break
  sleep 1
done

echo; echo "===== debian:12 (apt) ====="
# no_proxy so apt reaches the sibling container directly; the repo is unsigned, hence trusted=yes — the
# generated page says what that costs.
docker run --rm --network "$NET" -e http_proxy="${http_proxy:-}" -e https_proxy="${https_proxy:-}" \
  -e no_proxy="$WEB,localhost,127.0.0.1" debian:12 sh -c "
    set -e
    echo 'deb [trusted=yes] http://$WEB/deb stable main' > /etc/apt/sources.list.d/yoloman.list
    apt-get update -qq -o Dir::Etc::sourcelist=sources.list.d/yoloman.list -o Dir::Etc::sourceparts=- \
       -o APT::Get::List-Cleanup=0 2>&1 | tail -3
    apt-get install -y -qq --no-install-recommends yoloman-agent >/dev/null
    /usr/bin/agentic-mcpd --version 2>/dev/null || dpkg -l yoloman-agent | tail -1
    echo 'ok  apt installed yoloman-agent from the repository'
  "

echo; echo "===== almalinux:9 (dnf) ====="
docker run --rm --network "$NET" -e http_proxy="${http_proxy:-}" -e https_proxy="${https_proxy:-}" \
  -e no_proxy="$WEB,localhost,127.0.0.1" almalinux:9 sh -c "
    set -e
    cat > /etc/yum.repos.d/yoloman.repo <<REPO
[yoloman]
name=YOLO-MANager
baseurl=http://$WEB/rpm
enabled=1
gpgcheck=0
REPO
    dnf install -y -q --disablerepo='*' --enablerepo=yoloman yoloman-agent >/dev/null
    rpm -q yoloman-agent
    echo 'ok  dnf installed yoloman-agent from the repository'
  "
echo; echo "ALL OK"
