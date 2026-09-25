#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
bin_dir="$(cd "$project_dir" && swift build --show-bin-path)"
usage_app="$bin_dir/CodexUsageOverlay"
label="local.codex-usage-menu-bar"
agent_dir="$HOME/Library/LaunchAgents"
plist_path="$agent_dir/$label.plist"
log_dir="$HOME/Library/Logs/CodexUsageMenuBar"

mkdir -p "$agent_dir" "$log_dir"
chmod +x "$project_dir/watch-codex.sh"

cat > "$plist_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$project_dir/watch-codex.sh</string>
        <string>$usage_app</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$log_dir/companion.log</string>
    <key>StandardErrorPath</key>
    <string>$log_dir/companion-error.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$plist_path"
launchctl kickstart -k "gui/$(id -u)/$label"

echo "Installed and started $label. The menu bar app follows the Codex process."
