#!/bin/bash
# Installs what this task's checker needs into tools/. setup.sh runs it once, before any agent
# starts, because agents have no network. Replace it for your own task, or delete it.
set -eu
R=$(cd "$(dirname "$0")/.." && pwd); mkdir -p "$R/tools/bin"
if command -v uv >/dev/null; then
  uv venv -q --python "$(command -v python3)" "$R/tools/venv"
  uv pip install -q --python "$R/tools/venv/bin/python" pytest
else
  python3 -m venv "$R/tools/venv"; "$R/tools/venv/bin/pip" install -q pytest
fi
# tools/bin is on the agents' PATH and on the merge job's PATH
printf '#!/bin/sh\nexec "%s/tools/venv/bin/python" -m pytest -p no:cacheprovider "$@"\n' "$R" > "$R/tools/bin/pytest"
chmod +x "$R/tools/bin/pytest"
