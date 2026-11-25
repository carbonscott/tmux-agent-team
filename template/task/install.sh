#!/bin/bash
# Installs what this task's checker needs into tools/. setup.sh runs it once, before any agent
# starts, because agents have no network. Replace it for your own task, or delete it.
set -eu
R=$(cd "$(dirname "$0")/.." && pwd); mkdir -p "$R/tools/bin"
# the task's own environment, built by uv on the work directory's Python (tools/py, from setup.sh)
uv venv -q --python "$R/tools/py/bin/python" "$R/tools/venv"
uv pip install -q --python "$R/tools/venv/bin/python" pytest
# tools/bin is on the agents' PATH and on the merge job's PATH
printf '#!/bin/sh\nexec "%s/tools/venv/bin/python" -m pytest -p no:cacheprovider "$@"\n' "$R" > "$R/tools/bin/pytest"
chmod +x "$R/tools/bin/pytest"
