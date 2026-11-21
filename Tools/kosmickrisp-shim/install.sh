#!/bin/bash
# Compatibility entry point. The app and CLI share the verified, staged installer.
set -euo pipefail
cd "$(dirname "$0")/../.."
exec swift run gameport engine kosmickrisp "${1:-x64-crossover26.3-hb20261014}"
