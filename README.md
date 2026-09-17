# AmneziaWG 3 site-to-site setup

Connect two Debian/Ubuntu servers using one terminal. One server is the
**listener**: it has a public hostname/IP and accepts inbound UDP. The other
is the **connector**: it initiates outbound UDP and keeps the connection alive.
Only the two tunnel IPv4 addresses are routed. Existing default routes, DNS,
NAT and forwarding settings are retained.

## Start here

Put `amnezia-site-to-site.sh` on a Linux workstation, management machine, or
either server. The controller needs Bash, OpenSSH client and Linux coreutils.
Run it as your normal user to retain your SSH keys, agent and configuration:

```bash
bash ./amnezia-site-to-site.sh
```

Choose **Configure two servers from here**. The controller asks for:

1. Each server's SSH hostname/IP or SSH configuration alias.
2. SSH username, optional custom port, optional key file and optional jump host.
3. The listener's public UDP endpoint, tunnel port and two tunnel addresses.
4. A review of the plan before making changes.
5. Firewall handling and confirmation that provider firewalls are ready.

SSH uses your agent, existing keys, password login or a passphrase-protected
key. SSH/sudo request passwords directly; the script does not store them.
Blank username/port/key fields retain normal SSH configuration behavior.
Enter actual key paths; shell shortcuts such as `~` are not expanded in
prompts. SSH host-key verification remains enabled.

Choose **This machine** for one server when running the controller on it.
For example, the outbound-only connector can be local and reach the listener
by SSH. A separate management machine needs an SSH path to both servers,
possibly through jump hosts. Outbound-only UDP does not make inbound SSH
possible. Each SSH user needs root or permission to run commands with sudo;
sudo may ask for its password for each privileged action.

The controller checks that the connections have different machine IDs,
uploads the script, installs missing tools, exchanges public keys, prepares
the selected host firewall, starts both services and checks connectivity.
Private WireGuard keys remain on their own servers. The connector bundle
contains the shared AWG 3 header-protection secret and is transferred only
through SSH without printing it. Temporary SSH connection
sharing reduces repeated login prompts; connections are closed on exit.

Rerun with the same connection/tunnel settings after a pause or failure.
Matching configurations and keys are retained; conflicting settings/peers
are refused. Startup/ping failures retain configuration for troubleshooting.
Final verification requires a recent handshake on both servers, independently
of whether ICMP ping is permitted.

## Firewall choices

- **Active UFW:** adds persistent listener UDP, peer tunnel input and connector
  outbound UDP rules. UFW is never enabled automatically, which could block SSH.
- **Existing nftables input chain:** detects exactly one IPv4/inet input base
  chain, inserts tagged rules, and creates a systemd service to restore them
  at boot. Complex rulesets need administrator-managed rules. Active UFW
  should use UFW mode.
- **Administrator-managed:** leaves rules to your existing firewall management
  and waits for confirmation before starting.

Automatic rules allow the peer tunnel address to reach all local services.
Choose manual handling to restrict access to specific services. You still need
to allow listener UDP in the provider firewall, allow outbound UDP and its
replies on the connector, and account for restrictive output/forwarding chains
or additional firewall software. Provider control panels are not automated.

nftables mode creates `amnezia-site-firewall-INTERFACE.service` and makes the
tunnel depend on it. It does not flush or replace tables. Rules are inserted
before existing input rules. An `ip` family chain allows IPv4 UDP only: use
an IPv4 listener endpoint. Restarting `nftables.service` also restarts the
managed rules service. After a direct ruleset reload by another tool, restart
the managed rules service. Avoid this mode if another tool owns that chain.

## SSH over the tunnel

The listener can reach the outbound-only connector at its tunnel address:

```bash
ssh -p 2222 admin@10.203.77.2
```

Replace the port, user and address with your connector's settings. Its existing
SSH service must listen on the tunnel IP (or all interfaces), and its firewall
must allow that port. The script retains SSH daemon configuration and login keys.

## Local wizard and automation

To configure only the current machine:

```bash
sudo bash ./amnezia-site-to-site.sh wizard
```

The wizard covers installation, configuration, secure bundle and public-key exchange,
and startup. Pause while waiting for a peer key and resume later. Confirmation
prompts default to no. The controller automates the public exchange instead.

Automation commands remain available:

```bash
sudo bash ./amnezia-site-to-site.sh install
sudo bash ./amnezia-site-to-site.sh listener PUBLIC_ENDPOINT 51830 10.203.77.1 10.203.77.2
sudo bash ./amnezia-site-to-site.sh connector ./listener-bundle.txt
sudo bash ./amnezia-site-to-site.sh peer CONNECTOR_PUBLIC_KEY
sudo bash ./amnezia-site-to-site.sh firewall ufw
sudo bash ./amnezia-site-to-site.sh up
sudo bash ./amnezia-site-to-site.sh status
sudo bash ./amnezia-site-to-site.sh verify
```

Run listener/peer on the listener, connector on the connector, and install/up
on both. Securely copy the confidential `bundle.txt` to the connector for local-mode setup.
Controller commands `ensure-listener`/`ensure-connector` also accept matching
existing configurations. Re-enrolling the same peer public key is safe.

Defaults are interface `awg-site`, UDP `51830`, and tunnel addresses
`10.203.77.1`/`10.203.77.2`. These are suggestions; check for overlap with
current networks. Choose another interface in the wizard or consistently set
`AWG_INTERFACE` for command-line operations. No server names are built in.

## Installation and updates

`install` retains existing `awg`/`awg-quick` commands, which need a working
AmneziaWG module or userspace implementation. Clean amd64/arm64 Debian/Ubuntu
hosts install build dependencies and build official tools and userspace at
pinned commits. The latest stable Go archive is checked against the official
checksum manifest. Installation needs root, systemd, `/dev/net/tun`, and
internet access to package repositories, GitHub, Go and Go dependencies.
No Ubuntu PPA or third-party installer is added to Debian.

The kernel module is used when available, otherwise userspace, which generally
has lower throughput. Both implementations and tools must support AWG 3.
New configurations enable `HeaderProtectionKey`, set all `S1`–`S4` paddings
to at least 12 bytes, and enable `ContentPaddingAddition = 0-32`. Legacy
six-line bundles and configurations without header protection are refused
by the controller: choose a new interface for a fresh AWG 3 setup.
Build files and exact revisions are retained.

`Table = auto` enables routes only for `AllowedIPs`, which here contains the
peer tunnel IPv4 `/32`. No default route is installed. `Table = on` is not
a valid awg-quick setting; valid values are `auto`, `off`, or a table number/name.
Using `off` requires the administrator to install the peer route separately.

Update through the local wizard or:

```bash
sudo bash ./amnezia-site-to-site.sh update
```

APT installations upgrade only installed AmneziaWG packages from configured
repositories. Source installations in `/usr/local/bin` build current official
upstream `master` commits, stage both components and back up old executables
before replacing them. Commits may include changes newer than tagged releases.
Unrecognized installations are refused.

Updates retain keys/configuration but affect shared binaries/packages and all
AmneziaWG tunnels on the host. Use a maintenance window. The script does not
explicitly restart services during update; APT hooks may. The local wizard
offers a separate restart for this tunnel. Restart other userspace tunnels
to load new binaries. A DKMS update does not replace a loaded kernel module:
schedule a reboot if the module changed.

Build failures before replacement retain installed executables. For source
rollback, restore `awg`, `awg-quick`, `amneziawg-go` from the build directory's
`backup/` to `/usr/local/bin` and restart affected userspace tunnels. APT
rollback depends on available versions. Verify connectivity after updates.

## Administrator notes

For the default interface:

```bash
sudo systemctl status amnezia-site-awg-site
sudo journalctl -u amnezia-site-awg-site -n 50
sudo systemctl disable --now amnezia-site-awg-site
```

Configuration: `/etc/amnezia/amneziawg/awg-site.conf`. Root-only keys, settings,
confidential bundle and retained builds: `/etc/amnezia/site-to-site/awg-site/`.
Stopping the tunnel retains files and firewall rules. To remove managed
nftables rules, disable/stop `amnezia-site-firewall-awg-site.service`; remove
UFW rules through normal UFW administration.

For operators learning Linux, use the controller, SSH aliases for repeat
deployments, plan review and handshake verification. Keep a provider console
available for firewall administration. Useful future additions include saved
non-secret connection profiles, a diagnostics report, scoped service access
and a cleanup wizard.

References: [AmneziaWG userspace](https://github.com/amnezia-vpn/amneziawg-go)
and [AmneziaWG tools](https://github.com/amnezia-vpn/amneziawg-tools).
