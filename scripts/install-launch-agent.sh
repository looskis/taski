#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}
app_dir=${1:-"$repo_dir/dist/Taski.app"}
executable="$app_dir/Contents/MacOS/taski"
agent_dir="$HOME/Library/LaunchAgents"
log_dir="$HOME/Library/Logs/Taski"
agent_file="$agent_dir/com.kevinloo.taski.plist"

[[ -x "$executable" ]] || { print -u2 "Missing executable: $executable"; exit 2; }
mkdir -p "$agent_dir" "$log_dir"
sed -e "s|__EXECUTABLE__|$executable|g" -e "s|__LOG_DIR__|$log_dir|g" "$repo_dir/Packaging/com.kevinloo.taski.plist" > "$agent_file"
plutil -lint "$agent_file"
launchctl bootout "gui/$UID/com.kevinloo.taski" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$agent_file"
launchctl enable "gui/$UID/com.kevinloo.taski"
print "Installed com.kevinloo.taski from $app_dir"
