#!/bin/sh
# For testing on this Mac: prints what Regents Cloak wrote to the Mac's log
# in the last <minutes> (60 if not given), then the crash reports macOS has
# for Cloak and its parts. The app writes "opened <release>" at launch,
# each change of state, and "quit" at a clean end; a run with no "quit" was
# ended some other way. Reads only; nothing leaves the Mac.
# Usage: app/log.sh [minutes]
set -eu
minutes=${1:-60}
/usr/bin/log show --last "${minutes}m" --info --style compact \
	--predicate 'subsystem == "sh.regents.cloak.app"' | cut -c1-240
echo
echo "Crash reports:"
ls -lt "$HOME/Library/Logs/DiagnosticReports" | grep -i -E "RegentsCloak|cloak-|llama|tor-" | head -20 || echo "none"
