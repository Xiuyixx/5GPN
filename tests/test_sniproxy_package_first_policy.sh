#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
install="${root}/install.sh"
install_body="$(cat "${install}")"

if [[ "${install_body}" != *'apt-get install -y -qq sniproxy'* ]]; then
    echo "install.sh must try distro sniproxy package before source cloning from GitHub." >&2
    exit 1
fi

if [[ "${install_body}" != *'sniproxy package is unavailable and git is not installed for source build'* ]]; then
    echo "install.sh must fail clearly when package install and source-build prerequisites are unavailable." >&2
    exit 1
fi

python3 - "${install}" <<'PY'
import sys
from pathlib import Path
body = Path(sys.argv[1]).read_text()
fn = body.split('install_sniproxy() {', 1)[1].split('\n}\n\n# =============================================================================\n# quic-proxy', 1)[0]
package_pos = fn.find('apt-get install -y -qq sniproxy')
clone_pos = fn.find('git clone --depth=1 https://github.com/dlundquist/sniproxy.git')
if package_pos == -1 or clone_pos == -1 or not package_pos < clone_pos:
    raise SystemExit('install_sniproxy must try package installation before GitHub source clone')
PY

echo "sniproxy package-first policy OK"
