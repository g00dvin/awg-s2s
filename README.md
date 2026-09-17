# AmneziaWG 3.1 kernel-only site-to-site setup

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
uploads the script, bootstraps the kernel module/tools, exchanges public keys, prepares
the selected host firewall, starts both services and checks connectivity.
Private WireGuard keys remain on their own servers. The connector bundle
contains the shared AWG 3.1 header-protection key and peer PSK and is transferred only
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

`install` bootstraps **kernel-only AWG 3.1** on Debian/Ubuntu systemd hosts.
It installs distro build dependencies, DKMS and headers for the running kernel,
then builds official kernel/tools sources at pinned commits. No Ubuntu PPA is
added to Debian; Go and `/dev/net/tun` are not required. Root and internet access
to APT and GitHub are required. Kernel builds may take several minutes.

DKMS sources live under `/usr/src/amneziawg-VERSION/` and automatically rebuild
for future kernels when matching headers are installed. Tools are installed in
`/usr/local/bin`; existing distro packages are not removed. Retained builds,
source revisions and backups are recorded under this interface's state directory.
Previously installed DKMS versions are retained for rollback. Before future
kernel upgrades, have an administrator retire obsolete registrations with
`dkms remove -m amneziawg -v OLD_VERSION --all`, keeping the selected version.
Avoid mixing subsequent package-managed AWG upgrades with this source installer.

Installation fails clearly if running-kernel headers are unavailable or the module
cannot load. Secure Boot may require enrolling the DKMS signing key through the
machine/provider console; the script never disables Secure Boot. Containers
need host-level module administration and are not bootstrapped automatically.

The installer **never unloads an existing module or stops existing tunnels**.
If the installed module differs from the loaded module, installation reports
that maintenance/reboot is needed and returns failure. Reboot, then rerun the
same command/controller. Merely restarting a tunnel does not replace its module.
Use `kernel-check` to verify the loaded and installed module match.
Systemd checks this before startup and explicitly disables userspace fallback.

### Configuration defaults

New profiles use:

- Separate private keys on each host; a random shared header-protection key
  and a separate random per-peer preshared key, transferred only through SSH.
- `S1 = S2 = S3 = S4 = 32`, with `H1 = 1`, `H2 = 2`, `H3 = 3`, `H4 = 4`.
  Standard header values are recommended when header protection is enabled;
  the message type is still hidden by header protection.
- `ContentPaddingAddition = 16-64`, `RandomTrailers = off`,
  `DisableCookies = off`; default protocol timers are retained.
  Cookie replies retain DoS protection. Padding values are conservative project
  defaults, not a guarantee of censorship resistance.
- Kernel peer `AdvancedSecurity = on`, MTU 1280, and only the peer's tunnel /32.
- Connector-only junk packets (`Jc = 4`, `Jmin = 40`, `Jmax = 70`) and
  `PersistentKeepalive = 25`; the listener has no persistent keepalive.

All secret files are created with restrictive permissions. The confidential
eight-line `AWG-SITE-V3` bundle contains both shared secrets. Older bundles and
profiles are refused: choose a new interface and configure both servers together.
Updates do not silently rewrite existing configuration or rotate keys.
For stricter least privilege, select administrator-managed firewall handling
and allow only required services from the peer; automatic firewall handling
still permits all local services from the peer tunnel IP.

`Table = auto` routes only the configured peer IPv4 `/32`, not internet traffic.
`Table = on` is invalid; `off` requires manually installing the peer route.

### Updates and recovery

Update through the wizard or:

```bash
sudo bash ./amnezia-site-to-site.sh update
sudo bash ./amnezia-site-to-site.sh kernel-check
```

Updates resolve current official upstream `master` commits for both kernel and
tools, validate that the kernel identifies as 3.1, build before replacing
installed components, and retain previous tools/module and DKMS registrations.
Master commits are not necessarily tagged releases. GitHub API rate limits or
download failures abort the action; no unverified fallback installer is used.

Updates affect shared module/tools on the host, including other AWG tunnels.
Plan a maintenance window and keep console access available. If a reboot is
required, perform it before restarting services. The wizard offers to restart
only this project's tunnel after `kernel-check` succeeds. Existing keys,
addresses, routes and profiles are retained.

For source rollback, an administrator can reinstall a retained earlier DKMS
registration for the running kernel with `dkms install --force -m amneziawg
-v OLD_VERSION -k KERNEL_RELEASE`, restore backed-up tools to `/usr/local/bin`,
and reboot to load the matching module. Module backups are recovery artifacts,
not an automatic rollback system. Verify handshakes and connectivity afterward.

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

References: [AWG 3.1 configuration and security](https://docs.amnezia.org/documentation/amnezia-wg/),
[kernel module](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module)
and [tools](https://github.com/amnezia-vpn/amneziawg-tools).
