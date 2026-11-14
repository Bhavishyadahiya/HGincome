# HGincome verification — 2026-11-14

## Environment

- Linux x86_64, Bash 5.x, Docker Engine 29.x.
- `/dev/net/tun` available; tests ran in a new isolated directory.
- Existing containers were left unchanged.
- No Honeygain account credentials were used or submitted, and no account was registered.

## Verified results

| Check | Result |
| --- | --- |
| Bash syntax for every script; network fixture JavaScript syntax | Pass |
| Local Bash/mock-Docker regression suite | 50 checks passed |
| Official Honeygain amd64 image starts its help CLI without networking | Pass |
| Honeygain `-email`, `-pass`, `-device`, `-tou-accept` flags | Confirmed in image help |
| tun2proxy v0.8.5 Docker entrypoint includes `--setup` | Confirmed |
| HTTPS proxy endpoint scheme | Rejected by image; HGincome validation corrected |
| Explicit Docker `--device /dev/net/tun:/dev/net/tun` plus `NET_ADMIN` | Tunnel started successfully |
| Tunnel interface and default route | `tun0` present, `default dev tun0` |
| Numeric HTTP destination through SOCKS5 | Pass; proxy recorded CONNECT |
| DNS-over-TCP and HTTP destination by hostname | Pass; proxy recorded DNS/HTTP CONNECT, local DNS answered A/AAAA queries |
| Manual app/tunnel dependency-ordered restart | Pass; hostname HTTP remained usable |
| Real Docker: two synthetic account configurations, ten slots per account | 20 sleeping app containers + 20 real tunnel containers created |
| Repeated startup | Reused the same 40 containers |
| Account-specific status, logs, stop, restart | Pass; other account remained running |
| Account deletion and recreation | Pass; saved instance/device names retained |
| Final container/network cleanup | No test containers or test network remained; original containers unchanged |

## Test design

`tests/linux-network.sh` creates an **internal Docker network** with a local SOCKS5 proxy, DNS fixture, HTTP fixture, the real tun2proxy image, and an Alpine client in the tunnel namespace. The SOCKS5 fixture only accepts the documentation-range HTTP destination and test DNS destinations, forwarding them to the local target. Proxy logs provide evidence that traffic took the tunnel path. The test does not require a commercial proxy or contact Honeygain.

The Node.js fixture runs inside a disposable test container. HGincome's runtime and offline regression suite remain Bash-only plus Docker; no Python or host Node.js installation is required.

`tests/linux-lifecycle.sh` invokes the actual HGincome entrypoint against real Docker with two synthetic account configurations. A minimal locally built Alpine sleeping image replaces Honeygain, ignoring its supplied synthetic arguments. A thin tunnel image pins the interface name to `tun0` for repeatable restarts. This verifies orchestration and Docker behavior, not live Honeygain authentication or commercial proxy eligibility.

No host package installation was performed. Docker images were pulled and temporary test images built under the user's approval. Docker's legacy builder emitted a deprecation warning because buildx was absent; the builds succeeded without installing buildx.

The tunnel image warned that its custom resolver bind mount failed and it fell back to directly writing `/etc/resolv.conf`. DNS-over-TCP still passed with HGincome's explicit application resolver mount. This warning alone was not treated as a failed test.

An initial network test used an unsupported Alpine `ip -brief` display flag and stopped. It was corrected to `ip address show`; the rerun passed. A prior mock-suite deletion regression was fixed and the expanded final suite passed.

## Run the optional Linux integration tests

Only run these on an authorized Linux Docker host after approving image pulls and temporary container/image creation. Never use production credentials. From the reviewed HGincome checkout:

```bash
TEST_ROOT=$(mktemp -d /tmp/hgincome-integration.XXXXXX)
mkdir "$TEST_ROOT/project"
cp HGincome.sh properties.conf "$TEST_ROOT/project/"
cp -R tests "$TEST_ROOT/project/tests"

# These are Docker image downloads, not host package installations.
docker pull alpine:3.22
docker pull node:22-alpine
docker pull ghcr.io/tun2proxy/tun2proxy:v0.8.5

bash "$TEST_ROOT/project/tests/linux-network.sh" "$TEST_ROOT"
bash "$TEST_ROOT/project/tests/linux-lifecycle.sh" "$TEST_ROOT"
```

Both scripts validate the supplied layout before Docker mutations and use random per-run resource names/tags. The network test cleans up its labeled network/containers; the lifecycle test cleans up its instance's containers. Build contexts, source fixtures, and images remain for inspection. The lifecycle test builds images locally and needs a working Docker builder. Neither test submits Honeygain credentials.

## Images inspected

- `honeygain/honeygain:latest`, amd64; inspected digest:
  `sha256:159d120caac9f482074d3e8d82d4cc247cd07e65af37bcc8e6b89c60674d5ed4`
- `ghcr.io/tun2proxy/tun2proxy:v0.8.5`; CLI reports version `0.8.5`, build `49593bd`.
- Test fixtures used `node:22-alpine` and `alpine:3.22`.

Tags may change. Pin image digests for deployments requiring immutable inputs.

## Remaining unverified

- Actual Honeygain login, dashboard recognition of recreated devices, earnings, and account-specific limits.
- Whether operating multiple accounts and the proposed connections is allowed by current Honeygain terms.
- Commercial HTTP/SOCKS4/SOCKS5 proxies, proxy authentication, TLS destinations, public exit-IP uniqueness, throughput, and long-running stability.
- DNS bootstrap for proxy hostnames, alternate DNS modes, IPv6 behavior, and other CPU architectures.
- Fail-closed behavior, automatic pair ordering after Docker daemon/host failure, and proxy readiness beyond container process state.

The next live-account test should use only one authorized account and one eligible connection, after separately approving submission of its credentials to Honeygain. Configure secrets directly on the test host rather than posting them in chat.

## Retained artifacts

The isolated test source/configuration folder and pulled/built images were retained for inspection. No test containers or test network were left running. These artifacts are not a production deployment; remove them only after reviewing the exact targets and confirming cleanup.
