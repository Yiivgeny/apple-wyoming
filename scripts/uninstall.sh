#!/bin/zsh
set -euo pipefail

user_id="$(id -u)"
support_dir="${HOME}/Library/Application Support/Wyoming Apple Speech"
agent_path="${HOME}/Library/LaunchAgents/local.wyoming.apple-speech.plist"

/bin/launchctl bootout "gui/${user_id}" "${agent_path}" 2>/dev/null || true
rm -f "${agent_path}"
rm -rf "${support_dir}"

echo "Wyoming Apple Speech binary and LaunchAgent removed."
echo "Apple voice and Dictation assets were left installed and can be managed in System Settings."
