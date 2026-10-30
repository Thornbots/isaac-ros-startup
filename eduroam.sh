#!/bin/bash
# Configure existing eduroam profiles without reading or handling secrets.
set -euo pipefail
[[ "$(id -u)" == 0 ]] || { echo "run with sudo" >&2; exit 1; }
profile_list=$(nmcli -g UUID connection show)
profiles=()
if [[ -n "$profile_list" ]]; then mapfile -t profiles <<< "$profile_list"; fi
eduroam=()
priority=10
for uuid in "${profiles[@]}"; do
    [[ "$(nmcli -g connection.type connection show uuid "$uuid")" == 802-11-wireless ]] || continue
    ssid=$(nmcli -g 802-11-wireless.ssid connection show uuid "$uuid")
    if [[ "$ssid" == eduroam ]]; then
        eduroam+=("$uuid")
    else
        current=$(nmcli -g connection.autoconnect-priority connection show uuid "$uuid")
        if (( current >= priority )); then priority=$((current + 1)); fi
    fi
done
(( priority <= 999 )) || { echo "lower competing Wi-Fi autoconnect priorities below 999 first" >&2; exit 1; }
if (( ${#eduroam[@]} == 0 )); then
    cat <<EOF
No eduroam profile found. Substitute your identity, campus CA PEM path and RADIUS
server domain from campus IT, then run this interactively (NM stores the secret):
sudo nmcli --ask connection add type wifi con-name eduroam ssid eduroam connection.permissions '' connection.autoconnect yes connection.autoconnect-priority $priority wifi-sec.key-mgmt wpa-eap 802-1x.eap peap 802-1x.phase2-auth mschapv2 802-1x.identity '<id>' 802-1x.ca-cert '<campus CA PEM path>' 802-1x.domain-suffix-match '<RADIUS server domain>' 802-1x.password-flags 0
sudo nmcli --ask connection up id eduroam
EOF
    exit 0
fi
for uuid in "${eduroam[@]}"; do
    nmcli connection modify uuid "$uuid" connection.autoconnect yes \
        connection.autoconnect-priority "$priority" connection.permissions ''
done
echo "eduroam system profiles enabled at autoconnect priority $priority"
