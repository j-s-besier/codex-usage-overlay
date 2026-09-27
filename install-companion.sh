#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
if [[ -x "$script_dir/../MacOS/CodexUsageOverlay" ]]; then
    # Resources inside the installed .app; no source checkout or Swift needed.
    usage_app="$(cd "$script_dir/../MacOS" && pwd)/CodexUsageOverlay"
else
    cd "$script_dir"
    swift build
    bin_dir="$(swift build --show-bin-path)"
    usage_app="$bin_dir/CodexUsageOverlay"
fi
label="local.codex-usage-menu-bar"
agent_dir="$HOME/Library/LaunchAgents"
plist_path="$agent_dir/$label.plist"
log_dir="$HOME/Library/Logs/CodexUsageMenuBar"

mkdir -p "$agent_dir" "$log_dir"
# Serialize paths as plist strings, including spaces and XML metacharacters.
# JXA is included with macOS, so packaged installation needs no extra runtime.
/usr/bin/osascript -l JavaScript - "$plist_path" "$label" "$script_dir/watch-codex.sh" "$usage_app" "$log_dir" <<'JXA'
ObjC.import('Foundation');
function run(args) {
    const plist = {
        Label: args[1],
        ProgramArguments: ['/bin/bash', args[2], args[3]],
        RunAtLoad: true,
        KeepAlive: true,
        StandardOutPath: args[4] + '/companion.log',
        StandardErrorPath: args[4] + '/companion-error.log'
    };
    if (!$(plist).writeToFileAtomically(args[0], true)) {
        throw new Error('Could not write LaunchAgent plist');
    }
}
JXA

launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$plist_path"
launchctl kickstart -k "gui/$(id -u)/$label"

echo "Installed and started $label. The menu bar app follows the Codex process."
