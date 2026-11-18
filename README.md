# HGincome

A Bash + Docker Honeygain manager inspired by [InternetIncome-debloated](https://github.com/Bhavishyadahiya/InternetIncome-debloated) and [EAincome](https://github.com/Bhavishyadahiya/EAincome). It uses Honeygain email/password authentication, not EarnApp claim links.

**Multiple account configurations live in one folder. Each account defaults to 10 device slots, with a hard maximum of 10.** Two fully configured proxy accounts create 20 Honeygain containers and 20 tunnel containers.

> These are local configuration limits, not verified current Honeygain entitlements. This project does not bypass device, public-IP, account, location, or network restrictions. Check Honeygain's current [terms](https://www.honeygain.com/terms-of-use/), [help center](https://support.honeygain.com/), and your connection provider's rules before operating it. Only use authorized accounts and eligible connections. Ten devices on one public IP are not ten independent connections. Multiple owned accounts are not automatically permitted by the service.

## Requirements

- A **Linux Docker Engine host**, with Bash 4.4+ and standard coreutils.
- Docker daemon access for the user running HGincome. No automatic `sudo`, dependency installation, downloaded-script execution, or architecture emulation.
- **Proxy-only networking:** host `/dev/net/tun` and permission to create tunnel containers with `NET_ADMIN` are required. These are privileged network capabilities; review the tunnel image before using it.
- A host architecture supported by both selected images. The Honeygain amd64 image and tun2proxy v0.8.5 entrypoint were verified on an Arch Linux x86_64 Docker host; other architectures are untested.
- Your own Honeygain credentials and eligible, stable connections. A proxy endpoint must keep a suitable exit IP; rotating exits can change service identity or violate rules.

Windows Git Bash can run syntax checks. **Docker Desktop/Git Bash is not a supported proxy runtime**; run the manager on the Linux Docker host. Do not point it at a remote Docker daemon: bind mounts and `/dev/net/tun` must exist on the same host as the manager.

## Files

```text
HGincome/
  HGincome                 # account-first command launcher
  HGincome.sh              # implementation; legacy commands still supported
  properties.conf          # global settings
  accounts.conf            # private credentials/config for all accounts
  accounts.conf.example    # two-account example without real credentials
  proxies/
    main.txt               # first account's proxy list
    second.txt             # second account's proxy list
  restart.sh               # restart convenience wrapper
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

Edit `accounts.conf`, fill in your own credentials, and remove unused example sections. Create each proxy list named by `proxy_file`, such as `proxies/main.txt` and `proxies/second.txt`, with your own eligible proxies. `.hgincome/` is generated automatically; do not copy another installation's state.

Example account configuration:

```ini
[Main Account]
email=your-first-email@example.com
password=your-first-password
devices=10
proxy_file=proxies/main.txt

[Second Account]
email=your-second-email@example.com
password=your-second-password
devices=10
proxy_file=proxies/second.txt
```

- Each `[Account Name]` section adds one account, in file order. No separate account-name array is needed. Add another account by copying a section and changing its name, credentials, and proxy list.
- Names are case-sensitive and may contain 1–64 letters, digits, spaces, dots, underscores, or hyphens. Start with a letter or digit; do not end with a space. Quote names with spaces in CLI commands. Names such as `personal`, `Main Account`, `Work.HG`, and `Account-2` are supported.
- Required fields for startup: `email` and `password`. Both must be nonempty.
- Optional `devices` defaults to `DEVICES_PER_ACCOUNT=10` from `properties.conf`; the allowed range is 1–10. `proxy_file` defaults to `proxies/<Account Name>.txt`. **Proxies are the only supported connection mode**; there is no `network` setting to configure.
- The first non-comment proxy becomes slot `01`, the next slot `02`, through `10`. **Keep line ordering stable.** Extra valid proxies are not started; the first configured number are used.
- Relative proxy paths are resolved from the HGincome folder, not the current terminal directory.
- Optional `device_prefix` sets a stable device prefix. It must be unique, at most 29 characters, and contain only letters, digits, dots, underscores, or hyphens. Otherwise the manager derives a prefix from its saved instance ID and account ID.
- Duplicate sections/keys, unknown keys, invalid names, and data outside a section are rejected with line numbers without displaying values.
- Blank lines and full-line `#` or `;` comments are supported. CRLF line endings, a UTF-8 BOM, and a final line without a newline are accepted.

Put 10 proxies in `proxies/main.txt` and another 10 in `proxies/second.txt`, one per line:

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

### Literal values and compatibility

Section-based `accounts.conf` is parsed as data, **not executed as Bash**. Everything after the first `=` is preserved literally, including leading/trailing spaces, `#`, `;`, `=`, `$`, quotes, and backslashes. Do not surround values with quotes or append inline comments. For example, `password=p a$$#word=more` stores exactly `p a$$#word=more`. Write normal settings as `devices=10`, not `devices=10 # comment`; put comments on their own lines. Multiline values are not supported.

Existing Bash-array files remain supported when their first non-comment line starts with `ACCOUNT_IDS=`. **Only this legacy format is sourced as trusted Bash code**; never use an unreviewed legacy file. New setups should use the section-based example. `properties.conf` remains trusted Bash code.

To migrate an existing **proxy** setup, keep the same section names as the old account IDs, slot counts, proxy order, and device prefixes. Write the actual password value without Bash quoting or escaping. An old `network` value of `proxy` is accepted with a deprecation notice; remove that key. Legacy `ACCOUNT_NETWORK` must be absent or `proxy`. Direct configurations are rejected before startup; stop/delete any old direct containers before migrating. Equivalent proxy values retain the same device naming and container configuration signature; the manager never automatically rewrites your file.

Validate without contacting Docker or Honeygain:

```bash
bash HGincome --check
```

Review and accept Honeygain's current terms before setting this in `properties.conf`:

```bash
ACCEPT_TOU=true
```

Starting then supplies `-tou-accept` to the Honeygain container. HGincome never assumes acceptance from the presence of credentials.

## List accounts

```bash
bash HGincome --accounts
bash HGincome "Main Account" --accounts
```

Lists account names, configured device counts, and proxy-file paths in file order. It does not require Docker, completed credentials, or populated proxy files, and it never prints emails, passwords, or proxy URLs. It reads configured accounts, not live container state; use `--status` for containers. An empty account file reports no accounts.

## Run and manage

Use the section name from `[Account Name]` as the first argument. Each command manages that account's full group of configured devices and matching tunnels, not just one device:

```bash
bash HGincome "Main Account" --start
bash HGincome "Main Account" --status
bash HGincome "Main Account" --stop
bash HGincome "Main Account" --restart
bash HGincome "Main Account" --delete
```

For example, `Main Account` and `Second Account` each have 10 slots in the configuration above. `bash HGincome "Main Account" --start` starts only that account's devices; `bash HGincome "Second Account" --delete` removes only the second account's app/tunnel containers. Deletion still asks for confirmation and keeps account configuration, proxies, and the saved instance ID.

```bash
# Start every configured account by omitting the account argument.
bash HGincome --start

# Read application or tunnel logs for one slot in an account.
bash HGincome "Main Account" --logs --device 1 --tail 100
bash HGincome "Main Account" --logs --device 1 --tunnel

# Stop or restart all managed accounts.
bash HGincome --stop
bash HGincome --restart

# Optional: explicitly pull configured images (not account-specific).
bash HGincome --pull
```

`bash HGincome "Main Account" --check` validates configuration without launching Docker. `bash HGincome --help` shows the available commands. `HGincome.sh` accepts the same account-first syntax, and existing commands such as `bash HGincome.sh --start --account personal` remain supported. Specify the account only once. Both launchers resolve configuration relative to their own folder, so they can be called from another working directory.

`--start` reuses matching containers. If a device's credentials, proxy, network mode, images, prefix, or container options changed, it refuses to reuse stale containers. Previously started accounts remain running if a later startup fails; no whole-folder rollback or automatic deletion is performed.

Docker's configured restart policy controls host-reboot behavior. The default is `unless-stopped`, so explicitly stopped containers stay stopped. Container startup is **not proof of a successful Honeygain login, accepted device, reachable proxy, or earnings**. Inspect logs and your Honeygain dashboard. There is no watcher or end-to-end proxy health check.

### Change account settings or proxy assignments

Delete that account's existing containers before changing its slot count or reassigning proxies. When selected accounts contain leftover slots or a full-folder start finds a removed account, `--start` lists those containers and refuses to proceed. It does not silently delete them.

```bash
bash HGincome "Main Account" --delete
# Edit accounts.conf and proxies/main.txt.
bash HGincome "Main Account" --check
bash HGincome "Main Account" --start
```

`--delete` first inspects ownership labels, lists the selected containers, and prompts for `DELETE`. Use `--yes` only when intentionally confirming a noninteractive deletion:

```bash
bash HGincome "Main Account" --delete --yes
```

It removes only containers carrying this folder's instance label. Other Docker applications, other HGincome folders, images, account files, proxy files, and the saved instance ID are not removed. Status, logs, stop, restart, and delete do not require valid account credentials, so an account can still be cleaned up after its config is removed.

## Identity and isolation

The first successful startup saves a random ID in `.hgincome/instance-id`. Container names are:

```text
hgincome-<instance>-<internal-account-id>-01
hgincome-<instance>-<internal-account-id>-01-tun
```

Default Honeygain device names are `hg-<instance>-<internal-account-id>-01`. Existing lowercase account IDs up to 12 characters keep their original internal ID. Custom names use a deterministic short hash so Docker/device names remain valid and bounded; the readable name is stored in labels. Names are case-sensitive. Renaming a section changes its identity: delete/stop the old name's containers before renaming it, or use the old name to clean them up afterward. The same name and slot keep their device name after deletion/recreation as long as `.hgincome/instance-id` and the prefix remain unchanged. This preserves local naming; it does not guarantee Honeygain will recognize a recreated container as the same device.

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

## Attribution

The Honeygain CLI pattern comes from InternetIncome-debloated; the one-tunnel-per-proxy design follows EAincome. EarnApp-specific registration, certificates, images, and claim URLs are not included. Both reference repositories carry an MIT license; their copyright/permission notice is retained in `LICENSE`. The base README has separate wording inconsistent with its MIT file; resolve that upstream inconsistency before redistributing a derivative.
