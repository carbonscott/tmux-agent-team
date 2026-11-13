#!/bin/bash
# One-time setup: tools, database, central repository, one workspace per agent, agent settings.
set -eu
R=$(cd "$(dirname "$0")" && pwd); cd "$R"
cfg() { python3 "$R/harness/cfg.py" "$1"; }
for t in git python3 uv docker bwrap tmux claude; do command -v $t >/dev/null || { echo "missing: $t"; exit 1; }; done
mkdir -p harness/secrets records state/removed state/ci ws; chmod 700 harness/secrets
[ -d tools/venv ] || { uv venv -q tools/venv; uv pip install -q --python tools/venv/bin/python pytest; }
[ -d harness/.venv ] || { uv venv -q harness/.venv; uv pip install -q --python harness/.venv/bin/python "psycopg[binary]"; }

# database passwords: known to the gateway only
python3 - "$R" <<'PY'
import json, os, secrets, sys
R = sys.argv[1]; p = R + "/harness/secrets/db.json"
if not os.path.exists(p):
    agents = json.load(open(R + "/config.json"))["agents"]
    fd = os.open(p, os.O_WRONLY | os.O_CREAT, 0o600)
    os.write(fd, json.dumps({k: secrets.token_urlsafe(24) for k in ["admin"] + agents}).encode()); os.close(fd)
PY
C=$(cfg db.container)
if ! docker ps --format '{{.Names}}' | grep -qx "$C"; then
  docker rm -f "$C" >/dev/null 2>&1 || true
  ADMIN=$(python3 -c "import json;print(json.load(open('$R/harness/secrets/db.json'))['admin'])")
  docker run -d --name "$C" -e POSTGRES_PASSWORD="$ADMIN" -e POSTGRES_DB="$(cfg db.name)" \
    -p "$(cfg db.host):$(cfg db.port):5432" "$(cfg db.image)" >/dev/null
  for i in $(seq 30); do docker exec "$C" pg_isready -q -U postgres -d "$(cfg db.name)" && break; sleep 1; done; sleep 2
fi
harness/.venv/bin/python harness/setup_db.py

# central repository seeded with the frozen statements; direct pushes are refused
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
if [ ! -d central.git ]; then
  git init -q --bare -b main central.git
  T=$(mktemp -d); cp -r seed/. "$T/"; ( cd "$T"; git init -q -b main; git add -A
    git -c user.name=harness -c user.email=harness@team.local commit -q -m "Seed: statements and frozen tests"
    git push -q "$R/central.git" main ); rm -rf "$T"
  printf '#!/bin/sh\necho "direct pushes are refused: use team push / team mr" >&2\nexit 1\n' > central.git/hooks/pre-receive
  chmod +x central.git/hooks/pre-receive
  git -C central.git rev-parse main > state/seed_sha
fi
for a in $(cfg agents); do
  [ -d ws/$a ] && continue
  git clone -q central.git ws/$a
  ( cd ws/$a; git checkout -q -b agent/$a; git config user.name $a; git config user.email $a@team.local
    mkdir -p .gw/req .gw/resp
    # the spool and the stub dotfiles the sandbox shows inside a workspace are not part of the work
    printf '.gw/\n/.*\n!/.gitignore\n' >> .git/info/exclude )
done
chmod +x bin/* harness/*.sh *.sh
python3 harness/mk_settings.py
echo "setup complete. next: harness/test_gateway.sh, harness/selftest.sh, then ./launch.sh"
