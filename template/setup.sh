#!/bin/bash
# One-time setup: task toolchain, central repository, one workspace per agent, agent settings.
set -eu
R=$(cd "$(dirname "$0")" && pwd); cd "$R"
cfg() { python3 "$R/harness/cfg.py" "$1"; }
for t in tmux git python3 bwrap claude; do command -v $t >/dev/null || { echo "missing: $t"; exit 1; }; done
[ -f task/seed/STATEMENTS.md ] || { echo "task/seed/STATEMENTS.md is missing: describe the statements there"; exit 1; }
mkdir -p records state/removed state/ci ws tools/bin
[ -x task/install.sh ] && [ ! -e state/installed ] && { task/install.sh; touch state/installed; }

# central repository seeded with the task; direct pushes are refused
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
if [ ! -d central.git ]; then
  git init -q --bare -b main central.git
  T=$(mktemp -d); cp -r task/seed/. "$T/"; ( cd "$T"; git init -q -b main; git add -A
    git -c user.name=boss -c user.email=boss@team.local commit -q -m "Seed: statements and frozen files"
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
