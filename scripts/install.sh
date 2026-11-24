#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
language="ru-RU"
if [[ "${1:-}" == "--language" ]]; then
  language="${2:?Missing language after --language}"
fi

user_id="$(id -u)"
support_dir="${HOME}/Library/Application Support/Wyoming Apple Speech"
binary_dir="${support_dir}/bin"
installed_binary="${binary_dir}/wyoming-apple-speech"
agent_path="${HOME}/Library/LaunchAgents/local.wyoming.apple-speech.plist"
log_dir="${HOME}/Library/Logs/WyomingAppleSpeech"
temporary_plist="$(mktemp -t wyoming-apple-speech.plist)"
trap 'rm -f "${temporary_plist}"' EXIT

echo "Building release binary…"
swift build --package-path "${project_dir}" -c release --product wyoming-apple-speech

mkdir -p "${binary_dir}" "${HOME}/Library/LaunchAgents" "${log_dir}"
install -m 0755 \
  "${project_dir}/.build/release/wyoming-apple-speech" \
  "${installed_binary}"
for resource_bundle in "${project_dir}"/.build/release/*.bundle(N); do
  /usr/bin/ditto "${resource_bundle}" "${binary_dir}/${resource_bundle:t}"
done

echo "Preparing Apple Dictation assets for ${language}…"
"${installed_binary}" prepare --language "${language}"

/usr/bin/plutil -create xml1 "${temporary_plist}"
/usr/bin/plutil -insert Label -string "local.wyoming.apple-speech" "${temporary_plist}"
/usr/bin/plutil -insert ProgramArguments -json \
  "[\"${installed_binary}\",\"serve\",\"--host\",\"0.0.0.0\",\"--port\",\"10700\",\"--language\",\"${language}\"]" \
  "${temporary_plist}"
/usr/bin/plutil -insert RunAtLoad -bool true "${temporary_plist}"
/usr/bin/plutil -insert KeepAlive -json '{"SuccessfulExit":false}' "${temporary_plist}"
/usr/bin/plutil -insert ProcessType -string "Interactive" "${temporary_plist}"
/usr/bin/plutil -insert StandardOutPath -string "${log_dir}/stdout.log" "${temporary_plist}"
/usr/bin/plutil -insert StandardErrorPath -string "${log_dir}/stderr.log" "${temporary_plist}"
install -m 0644 "${temporary_plist}" "${agent_path}"

/bin/launchctl bootout "gui/${user_id}" "${agent_path}" 2>/dev/null || true
/bin/launchctl bootstrap "gui/${user_id}" "${agent_path}"
/bin/launchctl kickstart -k "gui/${user_id}/local.wyoming.apple-speech"

echo "Installed: ${installed_binary}"
echo "LaunchAgent: ${agent_path}"
echo "Wyoming endpoint: tcp://0.0.0.0:10700"
echo "Check: ${installed_binary} doctor --language ${language}"
