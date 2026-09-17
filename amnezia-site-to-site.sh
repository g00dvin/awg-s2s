#!/usr/bin/env bash
# Version: 1.1.1 (kernel-only AmneziaWG 3.1)
set -Eeuo pipefail
umask 077
export PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C

INTERFACE=${AWG_INTERFACE:-awg-site}
KERNEL_REV=4569c4c67f3a57414969260cafbbd04694fbaae0
TOOLS_REV=ee0f0a9aa34ff0a0da4b3433b9512781cfe02843
SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}")

fail() { echo "Error: $*" >&2; exit 1; }
usage() {
    cat <<'EOF'
Usage (run with sudo/root):
  bash amnezia-site-to-site.sh controller
  bash amnezia-site-to-site.sh wizard
  bash amnezia-site-to-site.sh install
  bash amnezia-site-to-site.sh update
  bash amnezia-site-to-site.sh kernel-check
  bash amnezia-site-to-site.sh listener ENDPOINT [PORT [LOCAL_IP PEER_IP]]
  bash amnezia-site-to-site.sh connector BUNDLE_FILE
  bash amnezia-site-to-site.sh peer PUBLIC_KEY
  bash amnezia-site-to-site.sh up
  bash amnezia-site-to-site.sh status
  bash amnezia-site-to-site.sh verify
  bash amnezia-site-to-site.sh firewall ufw|nft

Defaults: interface awg-site, UDP 51830, listener 10.203.77.1,
connector 10.203.77.2. Set AWG_INTERFACE to choose another interface.
listener saves a confidential AWG 3 bundle; connector prints its public key.
Run peer on the listener with that key, then up on both servers.
Only the peer's tunnel IPv4 /32 is routed. Firewall rules are managed separately.
Run without arguments to launch the step-by-step wizard.
Kernel-only AWG 3.1: install builds tools and a persistent DKMS module.
update preserves configuration and keys; loaded modules are never unloaded.
controller runs on either server or a separate Linux workstation (no local root
needed unless configuring this machine). SSH supports passwords, keys, agents,
custom ports, SSH config aliases and ProxyJump. Remote users need root or sudo.
EOF
}

shell_quote() {
    local value=${1//\'/\'\\\'\'}
    printf "'%s'" "$value"
}

command_text() {
    local argument
    for argument in "$@"; do
        shell_quote "$argument"
        printf ' '
    done
}

declare -A NODE_MODE NODE_HOST NODE_USER NODE_PORT NODE_KEY NODE_JUMP

connection_details() {
    local node=$1
    echo "Connection to the $node server"
    echo "1) SSH connection  2) This machine"
    ask "Connection type" 1
    case $ANSWER in
        1) NODE_MODE[$node]=ssh ;;
        2) NODE_MODE[$node]=local; return ;;
        *) fail "Choose SSH (1) or this machine (2)" ;;
    esac
    ask "SSH hostname, IP address or SSH config alias"
    [[ $ANSWER =~ ^[a-zA-Z0-9][a-zA-Z0-9_.:-]*$ ]] || fail "Invalid SSH host"
    NODE_HOST[$node]=$ANSWER
    ask "SSH username (use your SSH config username by leaving blank)"
    [[ -z $ANSWER || $ANSWER =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]] || fail "Invalid SSH username"
    NODE_USER[$node]=$ANSWER
    ask "SSH port (leave blank to use SSH config/default 22)"
    [[ -z $ANSWER || $ANSWER =~ ^[1-9][0-9]{0,4}$ ]] || fail "Invalid SSH port"
    [[ -z $ANSWER ]] || ((ANSWER <= 65535)) || fail "Invalid SSH port"
    NODE_PORT[$node]=$ANSWER
    echo "Leave the key blank for your SSH agent, standard keys, or password login."
    echo "SSH itself asks for passwords/passphrases; this script never stores them."
    ask "Private SSH key file (optional)"
    [[ -z $ANSWER || -f $ANSWER ]] || fail "SSH key file does not exist"
    NODE_KEY[$node]=$ANSWER
    ask "SSH jump host, for example user@jump.example:2222 (optional)"
    [[ -z $ANSWER || $ANSWER != -* && $ANSWER != *[[:space:]]* ]] || fail "Invalid jump host"
    NODE_JUMP[$node]=$ANSWER
}

ssh_arguments() {
    local node=$1
    SSH_ARGS=(-o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3
        -o ControlMaster=auto -o ControlPersist=600 -o "ControlPath=$CONTROL_DIR/$node-%C")
    [[ -z ${NODE_USER[$node]} ]] || SSH_ARGS+=(-l "${NODE_USER[$node]}")
    [[ -z ${NODE_PORT[$node]} ]] || SSH_ARGS+=(-p "${NODE_PORT[$node]}")
    [[ -z ${NODE_KEY[$node]} ]] || SSH_ARGS+=(-i "${NODE_KEY[$node]}" -o IdentitiesOnly=yes)
    [[ -z ${NODE_JUMP[$node]} ]] || SSH_ARGS+=(-J "${NODE_JUMP[$node]}")
}

on_node() {
    local node=$1 text=$2 wrapped
    if [[ ${NODE_MODE[$node]} == local ]]; then
        if [[ $EUID == 0 ]]; then bash -c "$text"; else sudo -- bash -c "$text"; fi
    else
        ssh_arguments "$node"
        wrapped="if [ \"\$(id -u)\" = 0 ]; then bash -c $(shell_quote "$text"); else sudo -- bash -c $(shell_quote "$text"); fi"
        ssh -tt "${SSH_ARGS[@]}" "${NODE_HOST[$node]}" "$wrapped"
    fi
}

node_command() {
    local node=$1
    shift
    on_node "$node" "$(command_text env "AWG_INTERFACE=$INTERFACE" bash "$REMOTE_SCRIPT" "$@")"
}

controller_cleanup() {
    local node
    for node in listener connector; do
        if [[ ${NODE_MODE[$node]:-} == ssh ]]; then
            ssh_arguments "$node"
            ssh "${SSH_ARGS[@]}" -O exit "${NODE_HOST[$node]}" >/dev/null 2>&1 || true
        fi
    done
    if [[ ${CONTROL_DIR:-} == /tmp/amnezia-controller.* ]]; then
        rm -rf -- "$CONTROL_DIR"
    fi
}

exchange_from_node() {
    local node=$1 file=$2 remote_uid text administrator_password
    if [[ ${NODE_MODE[$node]} == local ]]; then
        if [[ $EUID == 0 ]]; then EXCHANGE=$(cat "$file"); else EXCHANGE=$(sudo -- cat "$file"); fi
    else
        ssh_arguments "$node"
        remote_uid=$(ssh -T "${SSH_ARGS[@]}" "${NODE_HOST[$node]}" 'id -u')
        text=$(command_text cat "$file")
        if [[ $remote_uid == 0 ]]; then
            EXCHANGE=$(ssh -T "${SSH_ARGS[@]}" "${NODE_HOST[$node]}" "$text")
        elif ssh -T "${SSH_ARGS[@]}" "${NODE_HOST[$node]}" "sudo -n -- bash -c ':'" >/dev/null 2>&1; then
            EXCHANGE=$(ssh -T "${SSH_ARGS[@]}" "${NODE_HOST[$node]}" "sudo -n -- bash -c $(shell_quote "$text")")
        else
            read -r -s -p "Sudo password for $node (for confidential transfer): " administrator_password </dev/tty || fail "Input closed"
            printf '\n' >/dev/tty
            EXCHANGE=$(printf '%s\n' "$administrator_password" | ssh -T "${SSH_ARGS[@]}" "${NODE_HOST[$node]}" "sudo -S -p '' -- bash -c $(shell_quote "$text")")
            unset administrator_password
        fi
    fi
    [[ -n $EXCHANGE ]] || fail "Could not retrieve exchange information from $node"
}

controller() {
    [[ -t 0 ]] || fail "Controller requires an interactive terminal"
    command -v ssh >/dev/null || fail "Install the OpenSSH client on this machine first"
    echo "Configure both servers from this terminal"
    echo "The listener needs public inbound UDP. The connector only needs outbound UDP."
    echo "Both need SSH access from here, via a jump host, or one can be this machine."
    echo "SSH host-key checks remain enabled. Confirm unfamiliar host fingerprints with your administrator."
    connection_details listener
    connection_details connector
    [[ ${NODE_MODE[listener]} != local || ${NODE_MODE[connector]} != local ]] || fail "Choose two different servers"
    ask "Tunnel interface name" "$INTERFACE"; INTERFACE=$ANSWER; set_paths
    ask "Listener's public hostname or IPv4 address (used for UDP, not SSH)"
    local endpoint=$ANSWER port listener_ip connector_ip node encoded bundle_encoded verified=1
    [[ $endpoint =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || fail "Invalid UDP endpoint"
    ask "Tunnel UDP port" 51830; port=$ANSWER
    [[ $port =~ ^[1-9][0-9]{0,4}$ ]] && ((port <= 65535)) || fail "Invalid UDP port"
    ask "Listener tunnel IPv4 address" 10.203.77.1; listener_ip=$ANSWER; valid_ip "$listener_ip"
    ask "Connector tunnel IPv4 address" 10.203.77.2; connector_ip=$ANSWER; valid_ip "$connector_ip"
    [[ $listener_ip != "$connector_ip" ]] || fail "Tunnel addresses must differ"
    echo
    echo "Plan: $listener_ip <-> $connector_ip via $endpoint UDP $port, interface $INTERFACE"
    echo "Install missing tools, exchange public keys, configure firewalls and enable both services."
    echo "Existing matching configurations are resumed. Conflicting configurations are refused."
    echo "Provider firewalls must allow UDP $port; check that tunnel addresses do not overlap existing routes."
    if ! confirm "Apply this plan to both servers"; then return; fi
    CONTROL_DIR=$(mktemp -d /tmp/amnezia-controller.XXXXXXXX)
    trap controller_cleanup EXIT
    REMOTE_SCRIPT=/usr/local/lib/amnezia-site-to-site.sh
    encoded=$(base64 -w 0 "$SCRIPT_PATH")

    echo "Step 1/5: Check SSH/root access and install the script and tools"
    local listener_identity connector_identity
    for node in listener connector; do
        echo "Checking $node access (SSH/sudo may ask for a password)..."
        exchange_from_node "$node" /etc/machine-id
        if [[ $node == listener ]]; then listener_identity=$EXCHANGE; else connector_identity=$EXCHANGE; fi
    done
    [[ $listener_identity != "$connector_identity" ]] || fail "Both connections point to the same machine; choose two different servers"
    for node in listener connector; do
        on_node "$node" "set -e; umask 077; mkdir -p /usr/local/lib; printf '%s' $(shell_quote "$encoded") | base64 -d > $REMOTE_SCRIPT.new; bash -n $REMOTE_SCRIPT.new; mv $REMOTE_SCRIPT.new $REMOTE_SCRIPT"
        node_command "$node" install
    done
    echo "Step 2/5: Configure listener and securely transfer its AWG 3 bundle"
    node_command listener ensure-listener "$endpoint" "$port" "$listener_ip" "$connector_ip"
    exchange_from_node listener "$STATE/bundle.txt"
    bundle_encoded=$(printf '%s\n' "$EXCHANGE" | base64 -w 0)
    on_node connector "set -e; umask 077; printf '%s' $(shell_quote "$bundle_encoded") | base64 -d > $(shell_quote "$STATE/incoming-bundle.txt")"
    echo "Step 3/5: Configure connector and enroll its public key"
    node_command connector ensure-connector "$STATE/incoming-bundle.txt"
    exchange_from_node connector "$STATE/public.key"
    valid_key "$EXCHANGE"
    node_command listener peer "$EXCHANGE"

    echo "Step 4/5: Prepare host firewalls"
    for node in listener connector; do
        echo "$node firewall: 1) Active UFW  2) Existing nftables input chain  3) Administrator-managed"
        echo "Automatic rules allow the peer tunnel IP to reach local services. Choose manual for tighter restrictions."
        ask "Choose firewall handling for $node" 3
        case $ANSWER in
            1) node_command "$node" firewall ufw ;;
            2) node_command "$node" firewall nft ;;
            3) echo "Allow desired traffic from $INTERFACE; on the listener also allow inbound UDP $port." ;;
            *) fail "Choose 1, 2 or 3" ;;
        esac
    done
    if ! confirm "Are host and provider firewalls ready on both servers"; then
        echo "Configuration saved on both servers. Rerun controller with the same settings to finish."
        return
    fi
    echo "Step 5/5: Start both tunnels and check connectivity"
    node_command listener up
    node_command connector up
    if ! on_node connector "ping -c 5 -W 2 $(shell_quote "$listener_ip")"; then
        echo "Ping failed. Both configurations are saved. Check UDP access and latest handshake below."
    fi
    node_command listener status
    node_command connector status
    for node in listener connector; do
        if ! node_command "$node" verify; then verified=0; fi
    done
    if [[ $verified == 0 ]]; then
        echo "Configuration completed, but no recent handshake was confirmed on both servers."
        echo "Check the UDP endpoint, provider firewall and service logs, then rerun with the same settings."
        return 1
    fi
    echo "A recent WireGuard handshake is confirmed on both servers."
    echo "To use SSH over the tunnel: ssh -p YOUR_SSH_PORT YOUR_USER@$connector_ip"
    echo "The destination's SSH service must listen on its tunnel IP and its firewall must allow that SSH port."
    admin_notes
}

configure_firewall() {
    if [[ ${1:-} == nft ]]; then
        configure_nft_firewall
        return
    fi
    [[ ${1:-} == ufw ]] || fail "Supported automatic firewalls: ufw or nft"
    command -v ufw >/dev/null || fail "UFW not installed; use your administrator-managed firewall"
    ufw status | grep -q '^Status: active$' || fail "UFW is inactive; this script will not enable it and risk blocking SSH"
    [[ -f $STATE/role && -f $STATE/settings ]] || fail "Configure the tunnel first"
    local role
    role=$(cat "$STATE/role")
    mapfile -t settings < "$STATE/settings"
    if [[ $role == listener ]]; then
        ufw allow "${settings[3]}/udp" comment "AmneziaWG $INTERFACE"
    fi
    ufw allow in on "$INTERFACE" from "${settings[1]}" comment "AmneziaWG peer $INTERFACE"
    if [[ $role == connector ]]; then
        ufw allow out to any port "${settings[3]}" proto udp comment "AmneziaWG outbound $INTERFACE"
    fi
    echo "Persistent UFW rules added. Provider firewalls still need administrator configuration."
}

configure_nft_firewall() {
    command -v nft >/dev/null && command -v python3 >/dev/null || fail "nft and python3 are required for nftables detection"
    [[ -f $STATE/settings && -f $STATE/role ]] || fail "Configure the tunnel first"
    if command -v ufw >/dev/null && ufw status | grep -q '^Status: active$'; then
        fail "UFW manages this firewall; choose firewall ufw instead"
    fi
    local candidate family table chain firewall_unit
    candidate=$(nft -j list ruleset | python3 -c '
import json, sys
chains = [entry["chain"] for entry in json.load(sys.stdin)["nftables"]
          if "chain" in entry and entry["chain"].get("hook") == "input"
          and entry["chain"]["family"] in ("inet", "ip")]
if len(chains) != 1:
    raise SystemExit("Need exactly one IPv4/inet input base chain; use manual firewall management for this ruleset")
chain = chains[0]
print(chain["family"], chain["table"], chain["name"])
')
    read -r family table chain <<< "$candidate"
    [[ $family == inet || $family == ip ]] || fail "Unsupported nftables family"
    [[ $table =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ && $chain =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]] || fail "Use manual firewall management for these table/chain names"
    printf '%s\n' "$family" "$table" "$chain" > "$STATE/nft-settings"
    install -d /usr/local/lib
    if [[ $SCRIPT_PATH != /usr/local/lib/amnezia-site-to-site.sh ]]; then
        install -m 700 "$SCRIPT_PATH" /usr/local/lib/amnezia-site-to-site.sh
    fi
    firewall_unit=amnezia-site-firewall-$INTERFACE.service
    cat > "/etc/systemd/system/$firewall_unit" <<EOF
[Unit]
Description=AmneziaWG firewall rules for $INTERFACE
After=nftables.service
Before=$UNIT
PartOf=nftables.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/env AWG_INTERFACE=$INTERFACE bash /usr/local/lib/amnezia-site-to-site.sh firewall-apply
ExecStop=/usr/bin/env AWG_INTERFACE=$INTERFACE bash /usr/local/lib/amnezia-site-to-site.sh firewall-remove

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "/etc/systemd/system/$firewall_unit"
    install -d "/etc/systemd/system/$UNIT.d"
    printf '[Unit]\nRequires=%s\nAfter=%s\n' "$firewall_unit" "$firewall_unit" > "/etc/systemd/system/$UNIT.d/firewall.conf"
    systemctl daemon-reload
    systemctl enable "$firewall_unit"
    systemctl restart "$firewall_unit"
    echo "Rules inserted into $family $table $chain; enabled at boot via $firewall_unit."
    echo "If an external tool reloads nftables directly, restart $firewall_unit afterward."
    [[ $family != ip ]] || echo "These firewall rules allow IPv4 UDP only; use an IPv4 listener endpoint."
}

nft_firewall_rules() {
    local operation=$1 family table chain handle tag
    [[ -f $STATE/nft-settings ]] || fail "No managed nftables settings"
    mapfile -t nft_settings < "$STATE/nft-settings"
    family=${nft_settings[0]} table=${nft_settings[1]} chain=${nft_settings[2]}
    tag=amnezia-site-$INTERFACE
    if ! nft list chain "$family" "$table" "$chain" >/dev/null 2>&1; then
        [[ $operation == remove ]] && return
        fail "Configured nftables input chain is missing; restore your base firewall first"
    fi
    while read -r handle; do
        [[ $handle =~ ^[0-9]+$ ]] || continue
        nft delete rule "$family" "$table" "$chain" handle "$handle"
    done < <(nft -a list chain "$family" "$table" "$chain" | awk -v tag="$tag" 'index($0, "comment \"" tag "\"") {print $NF}')
    [[ $operation != remove ]] || return 0
    mapfile -t settings < "$STATE/settings"
    nft -f - <<EOF
insert rule $family $table $chain iifname "$INTERFACE" ip saddr ${settings[1]} counter accept comment "$tag"
EOF
    if [[ $(cat "$STATE/role") == listener ]]; then
        nft -f - <<EOF
insert rule $family $table $chain udp dport ${settings[3]} counter accept comment "$tag"
EOF
    fi
}

set_paths() {
    [[ $INTERFACE =~ ^[a-zA-Z][a-zA-Z0-9-]{0,14}$ ]] || fail "Invalid interface name"
    STATE=/etc/amnezia/site-to-site/$INTERFACE
    CONFIG_DIR=/etc/amnezia/amneziawg
    CONFIG=$CONFIG_DIR/$INTERFACE.conf
    SERVICE=/etc/systemd/system/amnezia-site-$INTERFACE.service
    UNIT=amnezia-site-$INTERFACE.service
}

ask() {
    local prompt=$1 default=${2:-}
    if [[ -n $default ]]; then
        read -r -p "$prompt [$default]: " ANSWER || fail "Input closed; rerun wizard to resume"
        ANSWER=${ANSWER:-$default}
    else
        read -r -p "$prompt: " ANSWER || fail "Input closed; rerun wizard to resume"
    fi
}

confirm() {
    ask "$1 (yes/no)" no
    [[ $ANSWER == yes || $ANSWER == y ]]
}

run_command() {
    AWG_INTERFACE="$INTERFACE" bash "$SCRIPT_PATH" "$@"
}

admin_notes() {
    cat <<EOF

Administrator notes
  Interface: $INTERFACE       Service: $UNIT
  Configuration: $CONFIG
  Keys and exchange files: $STATE
  Keep private.key on this server. The bundle contains a shared AWG 3 secret;
  transfer it only to the connector through SSH, never publish it.
  Allow the listener's UDP port in both host and provider firewalls.
  Allow replies to outbound UDP on the connector, and desired local traffic from $INTERFACE.
  Check tunnel IPs against existing routes before configuring either server.
  This setup routes only the peer tunnel IP; it does not enable NAT or subnet forwarding.
  Troubleshooting: journalctl -u $UNIT -n 50
  Stop and disable: systemctl disable --now $UNIT
EOF
}

verify_tunnel() {
    kernel_interface_check
    local now
    now=$(date +%s)
    if ! awg show "$INTERFACE" latest-handshakes | awk -v now="$now" '$2 > 0 && now - $2 <= 180 {found=1} END {exit !found}'; then
        echo "No recent handshake on $INTERFACE. Check that both services are started and UDP replies are allowed." >&2
        return 1
    fi
    echo "Recent handshake confirmed on $INTERFACE."
}

show_status() {
    echo "Service: $UNIT"
    systemctl is-active "$UNIT" || true
    if ip link show dev "$INTERFACE" >/dev/null 2>&1; then
        awg show "$INTERFACE"
        ip -brief address show dev "$INTERFACE"
        echo "A started service alone does not confirm connectivity; check the latest handshake and ping."
    else
        echo "Tunnel interface is not running."
    fi
}

wizard() {
    [[ -t 0 ]] || fail "Wizard requires an interactive terminal; use --help for automation commands"
    echo "AmneziaWG site-to-site setup"
    ask "Tunnel interface name" "$INTERFACE"
    INTERFACE=$ANSWER
    set_paths
    admin_notes
    echo
    echo "1) Install, configure and run"
    echo "2) Update AmneziaWG"
    echo "3) Show status"
    echo "4) Exit"
    ask "Choose an action" 1
    case $ANSWER in
        1) ;;
        2)
            echo "Updates affect shared AmneziaWG binaries/packages on this host, including other tunnels."
            echo "APT may run package-maintenance hooks. Plan a maintenance window. Keys are retained."
            if confirm "Proceed with the update"; then
                run_command update
                if [[ -f $SERVICE ]] && run_command kernel-check && confirm "Restart only $UNIT now (brief interruption)"; then
                    systemctl restart "$UNIT"
                    show_status
                fi
            fi
            return
            ;;
        3) show_status; return ;;
        4) return ;;
        *) fail "Choose 1, 2, 3 or 4" ;;
    esac

    echo "Step 1/4: Install or check AmneziaWG"
    echo "Build AWG 3.1 tools and a DKMS kernel module; matching source builds are retained."
    if ! confirm "Continue with installation/check"; then return; fi
    run_command install

    echo "Step 2/4: Configure this server"
    if [[ -f $STATE/role ]]; then
        echo "Resuming existing $(cat "$STATE/role") configuration for $INTERFACE."
    else
        echo "1) Listener: public inbound UDP"
        echo "2) Connector: outbound UDP only"
        ask "Server role" 2
        case $ANSWER in
            1)
                ask "Public listener hostname or IPv4 address"
                local endpoint=$ANSWER port local_ip peer_ip
                ask "UDP listen port" 51830; port=$ANSWER
                ask "This server's tunnel IPv4 address" 10.203.77.1; local_ip=$ANSWER
                ask "Connector's tunnel IPv4 address" 10.203.77.2; peer_ip=$ANSWER
                run_command listener "$endpoint" "$port" "$local_ip" "$peer_ip"
                ;;
            2)
                echo "First run this wizard on the listener and copy its confidential AWG 3 bundle through SSH."
                echo "Example: scp -P SSH_PORT USER@LISTENER:/etc/amnezia/site-to-site/$INTERFACE/bundle.txt ./listener-bundle.txt"
                ask "Path to the listener bundle" ./listener-bundle.txt
                run_command connector "$ANSWER"
                ;;
            *) fail "Choose listener (1) or connector (2)" ;;
        esac
    fi

    echo "Step 3/4: Exchange public keys and review firewall"
    require_profile
    if [[ $(cat "$STATE/role") == listener ]]; then
        echo "Securely copy this confidential AWG 3 bundle to the connector: $STATE/bundle.txt"
        if [[ ! -f $STATE/peer.key ]]; then
            ask "Paste the connector public key, or press Enter to finish later"
            if [[ -z $ANSWER ]]; then
                echo "Setup saved. Run wizard again after the connector has generated its public key."
                return
            fi
            run_command peer "$ANSWER"
        fi
    else
        echo "Enroll this public key on the listener before starting:"
        cat "$STATE/public.key"
        echo "On listener: AWG_INTERFACE=$INTERFACE bash amnezia-site-to-site.sh peer $(cat "$STATE/public.key")"
        if ! confirm "Has the listener enrolled this key"; then
            echo "Setup saved. Rerun wizard after enrollment."
            return
        fi
    fi
    mapfile -t settings < "$STATE/settings"
    echo "Listener UDP port: ${settings[3]}; local ${settings[0]}; peer ${settings[1]}"
    if ! confirm "Have you checked IP overlaps and prepared the host/provider firewalls"; then
        echo "Setup saved. Rerun wizard when the firewall is ready."
        return
    fi

    echo "Step 4/4: Start and enable at boot"
    if ! confirm "Start $UNIT and enable it at boot"; then return; fi
    run_command up
    show_status
    echo "Start the other server too, then test: ping -c 3 ${settings[1]}"
    if confirm "Test ping now"; then
        if ! ping -c 3 -W 2 "${settings[1]}"; then
            echo "Ping failed: check peer startup, UDP/firewall access, keys and latest handshake."
        fi
    fi
    admin_notes
}

valid_ip() {
    local address=$1 octet
    local -a octets
    [[ $address =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Invalid IPv4 address: $address"
    IFS=. read -r -a octets <<< "$address"
    for octet in "${octets[@]}"; do
        [[ $octet == 0 || $octet != 0* ]] || fail "IPv4 octets must not have leading zeros"
        [[ ${#octet} -le 3 ]] && ((10#$octet <= 255)) || fail "Invalid IPv4 address: $address"
    done
}

valid_key() {
    [[ $1 =~ ^[A-Za-z0-9+/]{43}=$ ]] || fail "Invalid public key"
    [[ $(printf '%s' "$1" | base64 -d | wc -c) -eq 32 ]] || fail "Invalid public key length"
}

require_profile() {
    [[ -f $STATE/header.key && -f $STATE/preshared.key && -f $STATE/profile && $(cat "$STATE/profile") == AWG-SITE-V3 ]] || fail "Legacy profile: choose a new interface and configure both ends together for AWG 3.1; existing keys/configuration are not overwritten"
}

kernel_check() {
    command -v modprobe >/dev/null || fail "Run install first (modprobe is missing)"
    modprobe amneziawg || fail "Cannot load the kernel module. Check Secure Boot signing, kernel headers and journalctl -k; userspace fallback is disabled"
    local installed loaded
    installed=$(modinfo -F srcversion amneziawg)
    loaded=$(cat /sys/module/amneziawg/srcversion)
    [[ -n $installed && $installed == "$loaded" ]] || fail "Installed and loaded AmneziaWG modules differ. Reboot during maintenance, then rerun; restarting a tunnel alone does not replace the module"
    [[ $(modinfo -F version amneziawg) == 3.1.* ]] || fail "AWG 3.1 kernel module required; run install"
    echo "AWG 3.1 kernel module loaded and matches the installed build."
}

kernel_interface_check() {
    ip -j -d link show dev "$INTERFACE" | python3 -c '
import json, sys
links = json.load(sys.stdin)
if not links or links[0].get("linkinfo", {}).get("info_kind") != "amneziawg":
    raise SystemExit("Expected a kernel AmneziaWG interface; userspace interfaces are refused")
'
}

ensure_kernel_headers() {
    local kernel_release=$1 candidate architecture
    if [[ -f /lib/modules/$kernel_release/build/Makefile ]]; then
        echo "Using existing headers for the running kernel: $kernel_release"
        return
    fi
    candidate=$(apt-cache policy "linux-headers-$kernel_release" | awk '/Candidate:/ {print $2}')
    if [[ -z $candidate || $candidate == '(none)' ]]; then
        echo "Headers for running kernel $kernel_release are not available in your configured APT repositories." >&2
        echo "No kernel upgrade or reboot was performed. Keep provider console access available." >&2
        if [[ $ID == debian ]]; then
            architecture=$(dpkg --print-architecture)
            case $architecture in
                amd64|arm64)
                    echo "For a standard Debian kernel, during maintenance run:" >&2
                    echo "  sudo apt-get install linux-image-$architecture linux-headers-$architecture" >&2
                    echo "  sudo reboot" >&2
                    ;;
                *) echo "Install your architecture's supported kernel and matching headers, then reboot." >&2 ;;
            esac
        else
            echo "Install headers from the kernel's original trusted source, or install a supported Ubuntu kernel and its matching headers, then reboot." >&2
        fi
        fail "Rerun this script after booting the matching kernel. Headers for a different kernel cannot build a module for $kernel_release"
    fi
    apt-get install -y "linux-headers-$kernel_release"
    [[ -f /lib/modules/$kernel_release/build/Makefile ]] || fail "Installed headers do not provide the running kernel's build tree; check the kernel package and /lib/modules/$kernel_release/build"
}

install_tools() {
    local mode=${1:-install}
    [[ -f /etc/os-release ]] || fail "Cannot identify operating system"
    . /etc/os-release
    [[ $ID == debian || $ID == ubuntu ]] || fail "Only Debian and Ubuntu are supported"
    [[ -d /run/systemd/system ]] || fail "A systemd host is required; containers need host-level module administration"
    local kernel_release build_dir module_version source_dir binary revision component source_repo protocol_version
    kernel_release=$(uname -r)
    [[ $kernel_release =~ ^[a-zA-Z0-9._+-]+$ ]] || fail "Invalid kernel release"
    install -d -m 700 "$STATE"
    apt-get update
    ensure_kernel_headers "$kernel_release"
    apt-get install -y ca-certificates curl python3 build-essential dkms kmod iproute2
    build_dir=$(mktemp -d "$STATE/build.XXXXXXXX")
    if [[ $mode == update ]]; then
        for component in kernel tools; do
            if [[ $component == kernel ]]; then
                source_repo=amneziawg-linux-kernel-module
            else
                source_repo=amneziawg-tools
            fi
            curl -fsSL "https://api.github.com/repos/amnezia-vpn/$source_repo/commits/master" -o "$build_dir/$component-commit.json"
            revision=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sha"])' "$build_dir/$component-commit.json")
            [[ $revision =~ ^[a-f0-9]{40}$ ]] || fail "Invalid upstream source revision"
            if [[ $component == kernel ]]; then KERNEL_REV=$revision; else TOOLS_REV=$revision; fi
        done
    fi
    module_version=3.1.20260812-${KERNEL_REV:0:12}
    if [[ $mode == install && -f /usr/local/share/amnezia-site-source-versions ]] &&
        grep -Fxq "kernel=$KERNEL_REV" /usr/local/share/amnezia-site-source-versions &&
        grep -Fxq "tools=$TOOLS_REV" /usr/local/share/amnezia-site-source-versions &&
        [[ -x /usr/local/bin/awg && -x /usr/local/bin/awg-quick ]] &&
        dkms status -m amneziawg -v "$module_version" -k "$kernel_release" | grep -q ': installed'; then
        kernel_check
        return
    fi
    echo "Building AWG 3.1 kernel $KERNEL_REV and tools $TOOLS_REV"
    curl -fsSL "https://codeload.github.com/amnezia-vpn/amneziawg-linux-kernel-module/tar.gz/$KERNEL_REV" -o "$build_dir/kernel.tar.gz"
    curl -fsSL "https://codeload.github.com/amnezia-vpn/amneziawg-tools/tar.gz/$TOOLS_REV" -o "$build_dir/tools.tar.gz"
    tar -xzf "$build_dir/kernel.tar.gz" -C "$build_dir"
    tar -xzf "$build_dir/tools.tar.gz" -C "$build_dir"
    protocol_version=$(sed -n 's/^#define WIREGUARD_VERSION "\(3\.1\.[0-9]*\)"$/\1/p' "$build_dir/amneziawg-linux-kernel-module-$KERNEL_REV/src/version.h")
    [[ $protocol_version =~ ^3\.1\.[0-9]+$ ]] || fail "Upstream is not a supported AWG 3.1 build; review before upgrading"
    module_version=$protocol_version-${KERNEL_REV:0:12}
    source_dir=/usr/src/amneziawg-$module_version
    if [[ ! -d $source_dir ]]; then
        cp -a "$build_dir/amneziawg-linux-kernel-module-$KERNEL_REV/src" "$source_dir"
        cat > "$source_dir/dkms.conf" <<EOF
PACKAGE_NAME="amneziawg"
PACKAGE_VERSION="$module_version"
AUTOINSTALL="yes"
BUILT_MODULE_NAME[0]="amneziawg"
DEST_MODULE_LOCATION[0]="/updates/dkms"
MAKE[0]="make KERNELRELEASE=\$kernelver WIREGUARD_VERSION=$protocol_version"
CLEAN="make clean KERNELRELEASE=\$kernelver"
EOF
    fi
    if [[ -z $(dkms status -m amneziawg -v "$module_version") ]]; then
        dkms add -m amneziawg -v "$module_version"
    fi
    if ! dkms status -m amneziawg -v "$module_version" -k "$kernel_release" | grep -Eq ': (built|installed)'; then
        dkms build -m amneziawg -v "$module_version" -k "$kernel_release"
    fi
    make -C "$build_dir/amneziawg-tools-$TOOLS_REV/src" -j "$(nproc)"
    make -C "$build_dir/amneziawg-tools-$TOOLS_REV/src" install PREFIX=/usr/local DESTDIR="$build_dir/staged" \
        WITH_WGQUICK=yes WITH_SYSTEMDUNITS=no WITH_BASHCOMPLETION=no
    install -d -m 700 "$build_dir/backup"
    for binary in awg awg-quick; do
        if [[ -f /usr/local/bin/$binary ]]; then
            cp -p "/usr/local/bin/$binary" "$build_dir/backup/$binary"
        fi
    done
    modinfo -n amneziawg > "$build_dir/backup/module-path.txt" 2>/dev/null || true
    if [[ -s $build_dir/backup/module-path.txt ]]; then
        cp -p "$(cat "$build_dir/backup/module-path.txt")" "$build_dir/backup/"
    fi
    dkms install --force -m amneziawg -v "$module_version" -k "$kernel_release"
    depmod -a "$kernel_release"
    for binary in awg awg-quick; do
        install -m 755 "$build_dir/staged/usr/local/bin/$binary" "/usr/local/bin/$binary.new"
        mv "/usr/local/bin/$binary.new" "/usr/local/bin/$binary"
    done
    install -d /usr/local/share
    printf '%s\n' "kernel=$KERNEL_REV" "tools=$TOOLS_REV" "dkms=$module_version" > "$build_dir/source-versions.txt"
    install -m 644 "$build_dir/source-versions.txt" /usr/local/share/amnezia-site-source-versions
    echo "Installed DKMS module and tools. Sources, previous binaries/module: $build_dir"
    echo "Existing tunnels were not stopped; obsolete DKMS versions are retained for rollback."
    kernel_check
}

update_tools() {
    echo "Updating official kernel/tools sources; keys and configuration are retained."
    install_tools update
    echo "No tunnel restarted. After kernel-check succeeds: systemctl restart $UNIT"
}

write_config() {
    local private_key config_tmp header_key
    private_key=$(cat "$STATE/private.key")
    header_key=$(cat "$STATE/header.key")
    config_tmp=$(mktemp "$CONFIG_DIR/$INTERFACE.XXXXXXXX")
    cat > "$config_tmp" <<EOF
[Interface]
PrivateKey = $private_key
Address = $LOCAL_IP/32
Table = auto
ListenPort = $PORT
MTU = 1280
Jc = 0
Jmin = 40
Jmax = 70
S1 = 32
S2 = 32
S3 = 32
S4 = 32
HeaderProtectionKey = $header_key
ContentPaddingAddition = 16-64
RandomTrailers = off
DisableCookies = off
H1 = 1
H2 = 2
H3 = 3
H4 = 4
EOF
    if [[ $ROLE == connector ]]; then
        sed -i 's/^Jc = 0$/Jc = 4/' "$config_tmp"
    fi
    if [[ -n ${PEER_KEY:-} ]]; then
        cat >> "$config_tmp" <<EOF

[Peer]
PublicKey = $PEER_KEY
PresharedKey = $(cat "$STATE/preshared.key")
AdvancedSecurity = on
AllowedIPs = $PEER_IP/32
EOF
        if [[ $ROLE == connector ]]; then
            printf 'Endpoint = %s:%s\nPersistentKeepalive = 25\n' "$ENDPOINT" "$PORT" >> "$config_tmp"
        fi
    fi
    mv "$config_tmp" "$CONFIG"
}

write_service() {
    local quick
    quick=$(command -v awg-quick)
    cat > "$SERVICE" <<EOF
[Unit]
Description=AmneziaWG site-to-site $INTERFACE
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=WG_QUICK_USERSPACE_IMPLEMENTATION=/bin/false
ExecStartPre=/usr/bin/env AWG_INTERFACE=$INTERFACE bash /usr/local/lib/amnezia-site-to-site.sh kernel-check
ExecStart=$quick up $CONFIG
ExecStartPost=/usr/bin/env AWG_INTERFACE=$INTERFACE bash /usr/local/lib/amnezia-site-to-site.sh kernel-interface-check
ExecStop=$quick down $CONFIG

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$SERVICE"
    if [[ $SCRIPT_PATH != /usr/local/lib/amnezia-site-to-site.sh ]]; then
        install -D -m 700 "$SCRIPT_PATH" /usr/local/lib/amnezia-site-to-site.sh
    fi
    systemctl daemon-reload
}

[[ ${1:-} != --help && ${1:-} != -h ]] || { usage; exit 0; }
trap 'error_status=$?; echo "Action failed. Check the message above; completed setup steps are retained. Rerun with the same settings to resume." >&2; exit "$error_status"' ERR
if [[ $# -eq 0 ]]; then
    [[ -t 0 ]] || fail "Interactive setup needs a terminal; use --help for automation commands"
    echo "1) Configure two servers from here (SSH controller)"
    echo "2) Configure only this server (local wizard)"
    ask "Setup mode" 1
    case $ANSWER in 1) set -- controller ;; 2) set -- wizard ;; *) fail "Choose 1 or 2" ;; esac
fi
if [[ $1 == controller ]]; then
    [[ $# -eq 1 ]] || fail "controller takes no arguments"
    controller
    exit
fi
[[ $EUID -eq 0 ]] || fail "Run with sudo or as root"
set_paths

if [[ $1 == ensure-listener || $1 == ensure-connector ]]; then
    action=${1#ensure-}
    shift
    if [[ -f $STATE/role ]]; then
        [[ $(cat "$STATE/role") == "$action" && -f $CONFIG && -f $SERVICE ]] || fail "Existing configuration has a different role or is incomplete"
        mapfile -t settings < "$STATE/settings"
        if [[ $action == listener ]]; then
            [[ $# -eq 4 && ${settings[0]} == "$3" && ${settings[1]} == "$4" && ${settings[2]} == "$1" && ${settings[3]} == "$2" ]] || fail "Existing listener settings differ; choose another interface"
        else
            [[ $# -eq 1 && -f $1 ]] || fail "Connector bundle required"
            mapfile -t bundle < "$1"
            [[ ${#bundle[@]} -eq 8 && ${bundle[0]} == AWG-SITE-V3 && ${settings[0]} == "${bundle[4]}" && ${settings[1]} == "${bundle[3]}" && ${settings[2]} == "${bundle[1]}" && ${settings[3]} == "${bundle[2]}" ]] || fail "Existing connector settings differ; choose another interface"
            grep -Fxq "PublicKey = ${bundle[5]}" "$CONFIG" || fail "Existing listener public key differs"
            [[ -f $STATE/header.key && $(cat "$STATE/header.key") == "${bundle[6]}" ]] || fail "Existing AWG 3 header protection key differs"
            [[ -f $STATE/preshared.key && $(cat "$STATE/preshared.key") == "${bundle[7]}" ]] || fail "Existing peer preshared key differs"
        fi
        require_profile
        echo "Matching $action configuration retained."
        exit
    fi
    set -- "$action" "$@"
fi

    case $1 in
    firewall-apply|firewall-remove)
        [[ $# -eq 1 ]] || fail "$1 takes no arguments"
        nft_firewall_rules "${1#firewall-}"
        ;;
    firewall)
        [[ $# -eq 2 ]] || fail "firewall ufw|nft"
        configure_firewall "$2"
        ;;
    wizard)
        [[ $# -eq 1 ]] || fail "wizard takes no arguments"
        wizard
        ;;
    update)
        [[ $# -eq 1 ]] || fail "update takes no arguments"
        update_tools
        ;;
    kernel-check)
        [[ $# -eq 1 ]] || fail "kernel-check takes no arguments"
        kernel_check
        ;;
    kernel-interface-check)
        [[ $# -eq 1 ]] || fail "kernel-interface-check takes no arguments"
        kernel_interface_check
        ;;
    install)
        [[ $# -eq 1 ]] || fail "install takes no arguments"
        install -d -m 700 "$STATE"
        install_tools
        exit
        ;;
    status)
        [[ $# -eq 1 ]] || fail "status takes no arguments"
        show_status
        exit
        ;;
    verify)
        [[ $# -eq 1 ]] || fail "verify takes no arguments"
        verify_tunnel
        ;;
    listener|connector)
        command -v awg >/dev/null && command -v awg-quick >/dev/null || fail "Run install first"
        kernel_check
        [[ ! -e $CONFIG && ! -e $STATE/role && ! -e $SERVICE ]] || fail "Interface already configured; choose another AWG_INTERFACE"
        ip link show dev "$INTERFACE" >/dev/null 2>&1 && fail "Interface already exists"
        ROLE=$1
        if [[ $ROLE == listener ]]; then
            [[ $# -eq 2 || $# -eq 3 || $# -eq 5 ]] || fail "listener ENDPOINT [PORT [LOCAL_IP PEER_IP]]"
            ENDPOINT=$2 PORT=${3:-51830} LOCAL_IP=${4:-10.203.77.1} PEER_IP=${5:-10.203.77.2}
            PEER_KEY=
        else
            [[ $# -eq 2 && -f $2 ]] || fail "connector requires a bundle file"
            mapfile -t bundle < "$2"
            [[ ${#bundle[@]} -eq 8 && ${bundle[0]} == AWG-SITE-V3 ]] || fail "An AWG 3 bundle (AWG-SITE-V3) is required; legacy bundles are not supported"
            ENDPOINT=${bundle[1]} PORT=${bundle[2]} PEER_IP=${bundle[3]} LOCAL_IP=${bundle[4]} PEER_KEY=${bundle[5]}
            valid_key "$PEER_KEY"
            valid_key "${bundle[6]}"
            valid_key "${bundle[7]}"
        fi
        [[ $ENDPOINT =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || fail "Endpoint must be an IPv4 address or hostname"
        [[ $PORT =~ ^[1-9][0-9]{0,4}$ ]] && ((PORT <= 65535)) || fail "Invalid UDP port"
        valid_ip "$LOCAL_IP"
        valid_ip "$PEER_IP"
        [[ $LOCAL_IP != "$PEER_IP" ]] || fail "Tunnel IPs must differ"
        if ss -H -lun | awk '{print $4}' | grep -Eq ":$PORT$"; then
            fail "UDP port $PORT is already in use"
        fi
        install -d -m 700 "$STATE" "$CONFIG_DIR"
        if [[ $ROLE == listener ]]; then
            [[ -e $STATE/header.key ]] || awg genkey > "$STATE/header.key"
            [[ -e $STATE/preshared.key ]] || awg genpsk > "$STATE/preshared.key"
        else
            printf '%s\n' "${bundle[6]}" > "$STATE/header.key"
            printf '%s\n' "${bundle[7]}" > "$STATE/preshared.key"
        fi
        [[ -e $STATE/private.key ]] || awg genkey > "$STATE/private.key"
        awg pubkey < "$STATE/private.key" > "$STATE/public.key"
        printf '%s\n' "$ROLE" > "$STATE/role"
        printf '%s\n' AWG-SITE-V3 > "$STATE/profile"
        printf '%s\n' "$LOCAL_IP" "$PEER_IP" "$ENDPOINT" "$PORT" > "$STATE/settings"
        write_config
        write_service
        if [[ $ROLE == listener ]]; then
            printf 'AWG-SITE-V3\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$ENDPOINT" "$PORT" "$LOCAL_IP" "$PEER_IP" "$(cat "$STATE/public.key")" "$(cat "$STATE/header.key")" "$(cat "$STATE/preshared.key")" > "$STATE/bundle.txt"
            echo "AWG 3 configured. Confidential connector bundle: $STATE/bundle.txt"
        else
            cat "$STATE/public.key"
        fi
        ;;
    peer)
        [[ $# -eq 2 ]] || fail "peer requires a public key"
        valid_key "$2"
        [[ -f $STATE/role && $(cat "$STATE/role") == listener ]] || fail "Run listener first"
        require_profile
        if [[ -e $STATE/peer.key ]]; then
            [[ $(cat "$STATE/peer.key") == "$2" ]] || fail "A different peer is already enrolled"
            echo "Matching peer key retained."
            exit
        fi
        systemctl is-active --quiet "$UNIT" && fail "Stop $UNIT before enrolling a peer"
        ROLE=listener PEER_KEY=$2
        mapfile -t settings < "$STATE/settings"
        LOCAL_IP=${settings[0]} PEER_IP=${settings[1]} ENDPOINT=${settings[2]} PORT=${settings[3]}
        write_config
        printf '%s\n' "$PEER_KEY" > "$STATE/peer.key"
        ;;
    up)
        [[ $# -eq 1 ]] || fail "up takes no arguments"
        [[ -f $CONFIG && -f $SERVICE ]] || fail "Configure listener or connector first"
        require_profile
        kernel_check
        grep -q '^\[Peer\]$' "$CONFIG" || fail "Enroll the connector public key first"
        grep -q '^HeaderProtectionKey = ' "$CONFIG" || fail "AWG 3 header protection is required; configure a new interface"
        systemctl enable --now "$UNIT"
        echo "Started $UNIT. Check status and ping the peer tunnel IP."
        ;;
    *) usage; exit 1 ;;
esac
