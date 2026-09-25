#!/bin/bash
set -euo pipefail

label="local.codex-usage-menu-bar"
plist_path="$HOME/Library/LaunchAgents/$label.plist"
launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
rm -f "$plist_path"
echo "Removed $label."
