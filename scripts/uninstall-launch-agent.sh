#!/bin/zsh
set -euo pipefail

agent_file="$HOME/Library/LaunchAgents/com.kevinloo.taski.plist"
launchctl bootout "gui/$UID/com.kevinloo.taski" 2>/dev/null || true
if [[ -f "$agent_file" ]]; then
  mv "$agent_file" "$HOME/.Trash/com.kevinloo.taski.plist.$(date +%s)"
fi
print "Uninstalled the Taski LaunchAgent; application data was retained."
