# HGincome

A Bash + Docker Honeygain manager inspired by [InternetIncome-debloated](https://github.com/Bhavishyadahiya/InternetIncome-debloated) and [EAincome](https://github.com/Bhavishyadahiya/EAincome). It uses Honeygain email/password authentication, not EarnApp claim links.

**Multiple account configurations live in one folder. Each account defaults to 10 device slots, with a hard maximum of 10.** Two fully configured proxy accounts create 20 Honeygain containers and 20 tunnel containers.

> These are local configuration limits, not verified current Honeygain entitlements. This project does not bypass device, public-IP, account, location, or network restrictions. Check Honeygain's current [terms](https://www.honeygain.com/terms-of-use/), [help center](https://support.honeygain.com/), and your connection provider's rules before operating it. Only use authorized accounts and eligible connections. Ten devices on one public IP are not ten independent connections. Multiple owned accounts are not automatically permitted by the service.

## Requirements

- A **Linux Docker Engine host**, with Bash 4.4+ and standard coreutils.
- Docker daemon access for the user running HGincome. No automatic `sudo`, dependency installation, downloaded-script execution, or architecture emulation.
- For proxy mode: host `/dev/net/tun` and permission to create tunnel containers with `NET_ADMIN`. These are privileged network capabilities; review the tunnel image before using it.
- A host architecture supported by both selected images. The Honeygain amd64 image and tun2proxy v0.8.5 entrypoint were verified on an Arch Linux x86_64 Docker host; other architectures are untested.
- Your own Honeygain credentials and eligible, stable connections. A proxy endpoint must keep a suitable exit IP; rotating exits can change service identity or violate rules.

Windows Git Bash can run syntax checks and the mock tests. **Docker Desktop/Git Bash is not a supported proxy runtime**; run the manager on the Linux Docker host. Do not point it at a remote Docker daemon: bind mounts and `/dev/net/tun` must exist on the same host as the manager.

## Files

```text
HGincome/
  HGincome.sh              # main entrypoint
  properties.conf          # global settings
  accounts.conf            # private credentials/config for all accounts
  accounts.conf.example    # two-account example without real credentials
  proxies/
    personal.txt           # first account's proxy list
    second.txt             # second account's proxy list
  restart.sh               # restart convenience wrapper
  tests/                   # isolated Bash mock-Docker tests
  .hgincome/               # generated private instance ID and resolver file
```

Adding more accounts does not require copying HGincome or creating another installation folder.

## Configure two accounts with 10 slots each

Private configuration and proxy lists are intentionally excluded from Git. After a fresh clone, create them locally (do not overwrite an existing account file):

```bash
if [ ! -e accounts.conf ]; then cp accounts.conf.example accounts.conf; fi
mkdir -p proxies
chmod 700 proxies
```

Edit `accounts.conf`, fill in your own credentials, and remove unused example accounts. Create each proxy list named by `ACCOUNT_PROXY_FILE`, such as `proxies/personal.txt` and `proxies/second.txt`, with your own eligible proxies. `.hgincome/` is generated automatically; do not copy another installation's state.

Example account configuration:

```bash
ACCOUNT_IDS=(personal second)

ACCOUNT_EMAIL[personal]='your-first-email@example.com'
ACCOUNT_PASSWORD[personal]='your-first-password'
ACCOUNT_DEVICES[personal]=10
ACCOUNT_NETWORK[personal]='proxy'
ACCOUNT_PROXY_FILE[personal]='proxies/personal.txt'

ACCOUNT_EMAIL[second]='your-second-email@example.com'
ACCOUNT_PASSWORD[second]='your-second-password'
ACCOUNT_DEVICES[second]=10
ACCOUNT_NETWORK[second]='proxy'
ACCOUNT_PROXY_FILE[second]='proxies/second.txt'
```

- Account IDs must start with a lowercase letter and contain 1–12 lowercase letters, digits, underscores, or hyphens.
- Omitting `ACCOUNT_DEVICES[id]` uses `DEVICES_PER_ACCOUNT=10` from `properties.conf`.
- The first non-comment proxy becomes slot `01`, the next slot `02`, through `10`. **Keep line ordering stable.** Extra valid proxies are not started; the first configured number are used.
- Relative proxy paths are resolved from the HGincome folder, not the current terminal directory.
- Optional `ACCOUNT_DEVICE_PREFIX[id]` sets a stable device prefix. It must be unique, at most 29 characters, and contain only letters, digits, dots, underscores, or hyphens. Otherwise the manager derives a prefix from its saved instance ID and account ID.

Put 10 proxies in `proxies/personal.txt` and another 10 in `proxies/second.txt`, one per line:

```text
socks5://username:password@host.example:1080
http://username:password@another-host.example:8080
socks5://third-host.example:1080
```

Supported schemes: `http`, `socks4`, `socks5`. HTTPS proxy endpoints (`https://`) are rejected because the verified tun2proxy v0.8.5 image does not list support for them; HTTPS destinations still work through a supported proxy. `socks5h` and `socks4a` normalize to `socks5` and `socks4`. Use URL-encoded reserved characters in proxy credentials. An explicit port from 1 to 65535 is required; IPv6 hosts must be bracketed. Blank lines, comment lines, CRLF, and a final line without a newline are accepted. Do not add inline comments or whitespace to URLs.

Reusing the same host/port endpoint across active slots is rejected, even with different credentials or schemes. **Different endpoints may still share a public exit IP**; this check is not proof of independent connections, connectivity, proxy authentication, or Honeygain eligibility. Endpoint aliases cannot reliably be detected offline.

Protect secrets on Linux:

```bash
chmod 600 accounts.conf proxies/*.txt
```

These configuration files are **trusted Bash code**. Never source configuration obtained from someone else without reviewing it. Quote passwords correctly: single-quoted strings preserve spaces, `$`, `!`, and glob characters. To include an apostrophe use a Bash literal such as `'first'\''second'`.

Validate without contacting Docker or Honeygain:

```bash
bash HGincome.sh --check
```

Review and accept Honeygain's current terms before setting this in `properties.conf`:

```bash
ACCEPT_TOU=true
```

Starting then supplies `-tou-accept` to the Honeygain container. HGincome never assumes acceptance from the presence of credentials.

## Run and manage

```bash
# Start every configured account.
bash HGincome.sh --start

# Start or inspect one account.
bash HGincome.sh --start --account personal
bash HGincome.sh --status --account personal

# Read application or tunnel logs for one slot.
bash HGincome.sh --logs --account personal --device 1 --tail 100
bash HGincome.sh --logs --account personal --device 1 --tunnel

# Stop without deleting configuration or identity.
bash HGincome.sh --stop
bash HGincome.sh --stop --account personal

# Restart applications and tunnels in dependency order.
bash HGincome.sh --restart
bash restart.sh --account personal

# Optional: explicitly pull configured images.
bash HGincome.sh --pull
```

`--start` reuses matching containers. If a device's credentials, proxy, network mode, images, prefix, or container options changed, it refuses to reuse stale containers. Previously started accounts remain running if a later startup fails; no whole-folder rollback or automatic deletion is performed.

Docker's configured restart policy controls host-reboot behavior. The default is `unless-stopped`, so explicitly stopped containers stay stopped. Container startup is **not proof of a successful Honeygain login, accepted device, reachable proxy, or earnings**. Inspect logs and your Honeygain dashboard. There is no watcher or end-to-end proxy health check.

### Change account settings or proxy assignments

Delete that account's existing containers before changing its slot count or reassigning proxies. When selected accounts contain leftover slots or a full-folder start finds a removed account, `--start` lists those containers and refuses to proceed. It does not silently delete them.

```bash
bash HGincome.sh --delete --account personal
# Edit accounts.conf and proxies/personal.txt.
bash HGincome.sh --check
bash HGincome.sh --start --account personal
```

`--delete` first inspects ownership labels, lists the selected containers, and prompts for `DELETE`. Use `--yes` only when intentionally confirming a noninteractive deletion:

```bash
bash HGincome.sh --delete --account personal --yes
```

It removes only containers carrying this folder's instance label. Other Docker applications, other HGincome folders, images, account files, proxy files, and the saved instance ID are not removed. Status, logs, stop, restart, and delete do not require valid account credentials, so an account can still be cleaned up after its config is removed.

### Direct mode

One account can use the host connection without a proxy:

```bash
ACCOUNT_IDS=(personal)
ACCOUNT_EMAIL[personal]='your-email@example.com'
ACCOUNT_PASSWORD[personal]='your-password'
ACCOUNT_NETWORK[personal]='direct'
ACCOUNT_DEVICES[personal]=1
```

Only **one direct device across the whole folder** is permitted. Proxy mode supplies separate network namespaces, not automatic permission to share one public IP or bypass Honeygain rules.

## Identity and isolation

The first successful startup saves a random ID in `.hgincome/instance-id`. Container names are:

```text
hgincome-<instance>-<account>-01
hgincome-<instance>-<account>-01-tun
```

Default Honeygain device names are `hg-<instance>-<account>-01`. The same account ID and slot keep their name after deletion/recreation as long as `.hgincome/instance-id` and the prefix remain unchanged. This preserves local naming; it does not guarantee Honeygain will recognize a recreated container as the same device.

**Keep `.hgincome/instance-id`.** Deleting it while containers exist loses management ownership and can lead to duplicate deployments. Back it up with your private configuration. Do not run copied folders sharing the same instance ID on the same Docker host; that would share management scope.

A `.hgincome/lock` directory prevents overlapping manager mutations. If a process is forcibly killed, a stale lock may remain. Check that no HGincome manager is running before removing the empty lock directory.

## Security and troubleshooting

- Honeygain CLI authentication requires credentials in container arguments. They are visible to administrators and anyone with Docker access via `docker inspect`; Docker access is effectively root-equivalent. A salted configuration digest is also stored in labels for stale-config detection, not as credential encryption.
- Proxy URLs are likewise in tunnel container arguments. Startup failures suppress raw Docker run output to avoid printing credentials. Do not use `bash -x`, publish Docker inspect output, or paste secrets/logs into issues. `--logs` intentionally displays the image's raw logs; those may contain sensitive information.
- Default Docker logs are rotated at `5m`, with two files per container. `ENABLE_LOGS=false` disables stored logs and makes `--logs` unavailable for those containers until recreated.
- Each Honeygain container joins its own tunnel's network namespace. The resolver file binds into the application; tunnel DNS defaults to `over-tcp`. `virtual` and `direct` are optional, but DNS behavior and IPv6 handling require real-host verification. Direct DNS may use the host connection depending on the tunnel configuration. Proxy mode is not a certified fail-closed privacy system.
- A running tunnel is only a process-state check. Failed authentication or unreachable exits can still produce a running process. Use tunnel logs and Honeygain's dashboard to investigate.
- The Honeygain amd64 CLI was verified using a help-only container with networking disabled. Real account login and current service policies remain unverified. Image tags are not immutable: pulling a changed `latest` tag does not update already created containers. Pin image digests for reproducibility; deliberately delete/recreate affected accounts to apply image updates.
- The verified tun2proxy v0.8.5 entrypoint includes `--setup`. TUN interface/routes, HTTP traffic through a SOCKS5 proxy, DNS-over-TCP, and a dependency-ordered restart passed an isolated real-Docker test on Linux. Neither the running-state check nor dependency-ordered manual restart guarantees route readiness for arbitrary proxies, fail-closed egress, or automatic recovery ordering after Docker daemon failures.

## Tests

```bash
for script in HGincome.sh restart.sh tests/*.sh; do bash -n "$script" || exit; done
bash tests/run.sh
```

The default `tests/run.sh` suite uses only Bash and a locally written Docker mock. It covers two accounts with 10 slots each, per-account operations, proxy syntax/duplicates, passwords with metacharacters, idempotency, stale configuration, locks, startup failure cleanup, deletion confirmation, and stable naming.

The mock proxy tests call the production device-pair function through a test-only driver so they work on hosts lacking Linux `/dev/net/tun`. **They do not bypass that requirement in the real entrypoint and do not prove real Docker networking works.** Fixtures use synthetic `example.invalid` credentials and documentation-range IPs. Each run keeps its isolated temporary fixture directory for inspection; the path is printed.

No Python, dependency installers, live Docker actions, or external credential submissions are used by `tests/run.sh`.

Separate opt-in Linux integration scripts, `tests/linux-network.sh` and `tests/linux-lifecycle.sh`, do use real Docker. The network test uses Node.js inside a test container only for its local SOCKS5/DNS/HTTP fixture; HGincome itself remains Bash + Docker and needs no Node.js or Python. These tests create labeled temporary containers and clean those containers/networks up. They assume test images are available and must only be run with approval on an isolated host. See [TESTING.md](TESTING.md) for the verified results and limitations.

## Attribution

The Honeygain CLI pattern comes from InternetIncome-debloated; the one-tunnel-per-proxy design follows EAincome. EarnApp-specific registration, certificates, images, and claim URLs are not included. Both reference repositories carry an MIT license; their copyright/permission notice is retained in `LICENSE`. The base README has separate wording inconsistent with its MIT file; resolve that upstream inconsistency before redistributing a derivative.
