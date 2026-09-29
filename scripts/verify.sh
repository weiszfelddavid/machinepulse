#!/bin/sh
set -eu

swift build
swift run MachinePulseVerifier
xcrun swift-format lint --strict --recursive Sources Tests
sh -n Sources/MachinePulseApp/Resources/collector.sh

if [ -n "${MACHINEPULSE_SSH_TARGET:-}" ]; then
    ssh -o BatchMode=yes -o ConnectTimeout=5 -o ClearAllForwardings=yes \
        "$MACHINEPULSE_SSH_TARGET" sh -s \
        < Sources/MachinePulseApp/Resources/collector.sh \
        | python3 -m json.tool >/dev/null
    echo "Remote collector: passed"
fi
