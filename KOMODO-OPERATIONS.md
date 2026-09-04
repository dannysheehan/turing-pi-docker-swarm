# Komodo Operations Runbook

This is the CLI-first runbook for operating Komodo after the Ansible deployment.
Use the root README and current playbooks as the authoritative infrastructure
interface.

## Ownership

Ansible owns Day-0 infrastructure and recovery:

- operating system, Docker, and Swarm;
- Keepalived, firewall, and Traefik;
- the FerretDB/Postgres database tier and Komodo Core;
- Komodo Periphery agents;
- foundational Komodo Server and Swarm resources;
- Swarm secrets and persistent host paths.

Komodo Resource Sync owns reviewed Day-2 application resources:

- application stacks and deployments;
- builds, procedures, schedules, variables, and user groups.

The Komodo CLI/API is for bootstrap, CI/CD triggers, status checks, and
one-off operations. Do not make the same resource authoritative in both
Ansible and Resource Sync.

## Database Tier

Komodo stores everything in a MongoDB-wire database. These nodes are Raspberry
Pi CM3+ (Cortex-A53, ARMv8-A), and MongoDB 5.0+ requires ARMv8.2-A with LSE
atomics, so stock MongoDB is permanently capped at the end-of-life 4.4 series
here. The cluster therefore runs **FerretDB v2 over Postgres 17 + the
DocumentDB extension**, which is the path Komodo documents for hosts that
cannot run current MongoDB.

This replaces a three-member Mongo replica set with a single Postgres
instance. That costs no real availability, because Komodo Core is a single
replica pinned to the primary manager regardless.

`postgres`, `ferretdb`, and `komodo-core` are all pinned to
`swarm_primary_manager`, because the Postgres data directory and Core's Noise
keypair are node-local bind mounts under `/mnt/dietpi_userdata`.

Keep the two database images version-matched. The `postgres-documentdb` tag
names the FerretDB release it pairs with, and upstream warns that updates
between them can be breaking.

Inspect the database directly:

```sh
docker --context tpi service ls | rg 'postgres|ferretdb'

cid=$(docker ps --quiet --filter 'name=komodo_postgres\.1\.' | head -n1)
docker exec "$cid" psql -U komodo_user -d postgres -tAc \
  "SELECT extname||' v'||extversion FROM pg_extension ORDER BY 1;"
```

`documentdb` and `documentdb_core` must both be present. FerretDB cannot serve
the MongoDB wire protocol until they are, and Komodo Core will crash-loop
against a database that lacks them.

## Backups

Komodo backs up its own database through the **Backup Core Database**
procedure, created automatically and scheduled daily at 01:00. It writes
gzip-compressed per-collection dumps to `/backups` in the Core container and
retains the most recent 14. Because it works at the MongoDB wire-protocol
level it is agnostic to FerretDB sitting on Postgres.

`/backups` is mounted from the NAS rather than node storage, so a backup
survives total loss of the node holding the database. Dump files need no
particular ownership, which matters because the export uses `root_squash`.

Verify a backup has actually landed:

```sh
ls -la /srv/nfs/backups/komodo
```

An empty directory the morning after a deploy means the procedure ran with
nowhere to write. Confirm the mount is present:

```sh
cid=$(docker ps --quiet --filter 'name=komodo_komodo-core\.1\.' | head -n1)
docker exec "$cid" ls /backups
```

### Restoring

`km database restore` in Komodo 2.3.2 **ignores the database configuration it
is given**. It always connects to `localhost:27017` with no credentials, no
matter what `KOMODO_DATABASE_ADDRESS`, `KOMODO_DATABASE_URI`, or a
`komodo.cli.toml` `[database]` table says — `km config` resolves those settings
correctly, and then the subcommand does not use them. Against an authenticated
FerretDB it fails with:

```text
Command createIndexes requires authentication
```

The way through is to give it exactly the endpoint it insists on: a throwaway
FerretDB with authentication disabled, reachable only inside its own container
network namespace, destroyed as soon as the restore finishes. Nothing is
exposed on the database side, because that FerretDB still authenticates to
PostgreSQL as `komodo_user` through its own connection URL.

Run this from a healthy manager, with the backups export mounted at `/backups`
and `$PW` set to the `postgres-password` value:

```sh
docker run -d --name restore-ferretdb \
  -e FERRETDB_AUTH=false \
  -e FERRETDB_POSTGRESQL_URL="postgres://komodo_user:${PW}@<db-host>:5432/postgres" \
  ghcr.io/ferretdb/ferretdb:2.7.0

docker run --rm --network container:restore-ferretdb \
  -v /backups:/backups:ro \
  -e KOMODO_CLI_BACKUPS_FOLDER=/backups \
  --entrypoint /usr/local/bin/km \
  ghcr.io/moghtech/komodo-core:2.3.2 \
  database restore -r 2026-09-02_01-00-01 -y

docker rm -f restore-ferretdb
```

Omit `-r` to restore the most recent folder. Scale `komodo-core` to 0 first if
the stack is running, so Core does not write while the restore is in progress.

A successful run reports a line per collection:

```text
[User]: Restored 1 items
[Server]: Restored 7 items
[Stats]: Restored 189289 items
Finished restoring database ✅
```

## Placement: Nothing Is Pinned

Neither service carries a placement constraint. FerretDB is stateless and
Core's key material lives on NFS, so Swarm may schedule either anywhere in the
cluster and reschedule it after a node failure without operator involvement.

This was not always true, and the reason it changed is worth recording.

Until 2026-09-04 the database ran as a Swarm service on one node's eMMC. PGDATA
is node-local, so `postgres`, `ferretdb` and `komodo-core` were all pinned to
`komodo_db_node`. On 2026-09-04 that node's storage failed: the kernel and
network stack stayed up — it answered ICMP and dropbear kept accepting TCP on
22 — but every read from disk failed, so SSH key authentication was refused and
the Docker heartbeat stopped. Swarm marked the node `Down` and reported:

```text
no suitable node (scheduling constraints not satisfied on 6 nodes;
1 node not available for new tasks)
```

Komodo was down for hours against six healthy nodes it was not permitted to
use, and the scheduled backup had not run since 2026-09-02.

The fix was to move PostgreSQL off the cluster entirely. See below.

### Unpinning exposed an encrypted-overlay firewall gap

`komodo_back` is created with `--opt encrypted`. Docker does not carry an
encrypted overlay's data plane over udp/4789 between nodes; it wraps it in
**IPsec ESP (IP protocol 50)**. The firewall allowed 2377, 7946 and 4789 but
had no ESP rule, so the moment Core and FerretDB landed on different nodes the
data plane was silently dropped while DNS kept resolving over the 7946 control
plane. The symptom is distinctive:

```text
DNS ferretdb  -> 10.0.2.64        (resolves fine)
TCP  ferretdb:27017 -> CLOSED     (data plane dropped)
ping 10.0.2.12 (task IP) -> FAIL  (but the underlay pings fine)
```

and Core exits with:

```text
FATAL: Failed to initialize database::Client | Server selection timeout:
No available servers. Topology: { Servers: [ { Address: ferretdb:27017 } ] }
```

`roles/swarm_firewall` now emits `-p esp -j ACCEPT` for every cluster peer. The
gap had been latent since the network was created — it could not surface while
every service on that network was pinned to one node.

To check the rule is present:

```sh
sudo iptables -S ANSIBLE-INPUT | grep esp
```

### Core's identity changes if /config is lost

Core generates a fresh Noise keypair when `/config/keys/core.key` is missing,
and Periphery **pins** the Core key it first saw, in
`/etc/komodo/keys/core.pub`. After a Core identity change every agent refuses
to log in:

```text
Periphery failed to validate Core public key: ... is invalid
```

Recovery is to delete `/etc/komodo/keys` on each agent and restart `periphery`.
The agent then generates a new keypair, learns the new Core key, and presents
itself for approval; Core records the offered key as `attempted_public_key` and
rejects the login until an admin approves it. Approve with
`UpdateServerPublicKey` — **after** confirming the offered key matches what the
agent actually holds on disk:

```sh
sudo cat /etc/komodo/keys/periphery.pub   # compare to attempted_public_key
```

Note this is a mutual mismatch after a restore: agents rotate their own keys on
a schedule (`auto_rotate_keys`), so a backup older than the last rotation also
holds stale Periphery keys. Fixing only one direction is not enough.

## Storage Layout and Why It Is What It Is

| What | Where | Why |
|---|---|---|
| PostgreSQL data | external host, DBA-owned | removes the single point of failure |
| Core `/config` (Noise keypair) | NFS on the NAS | lets Core reschedule without losing its identity |
| Backups | NFS on the NAS | must survive total loss of any one node |

**PostgreSQL could not live on the NAS, which is why it left the cluster.**
PGDATA must be owned by the in-image postgres user (uid 999, mode 0700) and
PostgreSQL refuses to run as root. The NFS export accepts writes from uid 0
only: uid 999, 1000, 1024 and 1026 are all denied even on a 0777 directory,
because the NAS applies its own access control on top of POSIX permissions.
Those two facts are mutually exclusive. With no shared-storage option, the
database either pinned the control plane to one node or moved off the cluster.

Backups work precisely because Komodo Core runs as **root** in its container,
and root is the one uid the export accepts.

**Core `/config` on NFS is proven to work.** Verified on 2026-08-29: Core
starts with its keypair on an NFS volume, writes `core.key` and `core.pub` as
`0600` owned `0:0`, and reports the **same public key after a restart**. That
last point is what matters, because a Core that returned with a fresh identity
would have to re-enroll every Periphery agent.

This depends on `root_squash` being disabled on the export. If squashing is
re-enabled the files become owned by the mapped uid; Core would be squashed to
the same uid so it would probably still match, but that combination is
untested.

## The External Database

FerretDB stays on the Swarm, so port 27017 is never exposed beyond the overlay
network. Only FerretDB talks to PostgreSQL, over `komodo_pg_host:5432`.

Note that `komodo_pg_database` (default `postgres`) and
`komodo_database_db_name` (default `komodo`) are different things. FerretDB
maps every MongoDB database it serves into a single PostgreSQL database, so
`postgres` is the PostgreSQL database carrying the DocumentDB extension and
`komodo` is the MongoDB-level name Core uses inside it.

Two prerequisites belong to whoever owns the database host. The role asserts
them indirectly — FerretDB will not start without them — but cannot create
them:

- the DocumentDB extension installed in `komodo_pg_database`
- `komodo_db_user` granted **`documentdb_admin_role`**

Role membership is required, not individual table grants. DocumentDB creates a
table per collection at runtime, so any grant enumerated ahead of time is
correct until Komodo creates its next collection and then fails with
`permission denied for table ...`.

## Rotating the Postgres Password

The password is embedded verbatim in the FerretDB `postgres://` URL, so it must
be 20-128 alphanumeric characters — reserved URL characters would corrupt the
connection string, and the role asserts this.

Change it on the database host first, then let Ansible catch up. On the
external host, as a superuser:

```sql
ALTER ROLE komodo_user WITH PASSWORD '<new-value>';  -- pragma: allowlist secret
```

Then update `postgres-password` in 1Password to the same value and re-run the
`database` tag. Ansible rotates the Swarm secret and the FerretDB URL, and
FerretDB restarts against the new credentials.

## Onboarding Keys

Enrollment keys are short-lived (30 minutes) and non-privileged. The finalize
phase disables the key it created, and the prepare phase additionally revokes
any still-enabled `ansible-swarm-bootstrap-*` key left behind by an earlier run
that failed before finalize.

Audit them at any time:

```sh
km list --help   # no CLI subcommand for onboarding keys; use the API
curl -k -sS https://komodo.home.example.com/read/ListOnboardingKeys \
  -H "authorization: $JWT" -H 'content-type: application/json' -d '{}'
```

Any key showing `enabled=true` after a completed run should be revoked with
`UpdateOnboardingKey` (`enabled: false`) and then `DeleteOnboardingKey`.

## Rebuilding From Scratch

`96-komodo-teardown.yml` removes the stack, the database volumes, Core's key
material, and the Periphery keypairs. It is irreversible and destroys every
Komodo-defined resource: servers, stacks, procedures, syncs, users, and API
keys.

```sh
uv run --frozen ansible-playbook 96-komodo-teardown.yml \
  -i hosts.yml -e komodo_teardown_confirm=true --ask-vault-pass

uv run --frozen ansible-playbook 04-services.yml \
  -i hosts.yml --ask-vault-pass
```

The rebuild re-onboards every Periphery agent, so the Server resources come
back with fresh keys. Recreate the Resource Sync afterwards.

## Install the CLI

The official Linux installer installs `km` to `${HOME}/.local/bin/km`:

```sh
curl -sSL https://raw.githubusercontent.com/moghtech/komodo/main/scripts/install-cli.py \
  | python3 - --user
export PATH="$HOME/.local/bin:$PATH"
km --help
km config
```

For a temporary container-based CLI:

```sh
alias km='docker run --rm -v "$HOME/.config/komodo:/config" ghcr.io/moghtech/komodo-cli:2 km'
km config
```

Pin the CLI binary or image version in CI. Do not use an unpinned latest
artifact for automation.

## Configure CLI Authentication

Create a dedicated Komodo API key for automation. Do not use the interactive
admin password in CI. The CLI supports profiles in
`${HOME}/.config/komodo/komodo.cli.toml` or environment variables.

Example config with mode `0600`:

```toml
default_profile = "TuringPi"

[[profile]]
name = "TuringPi"
host = "https://komodo.home.example.com"
key = "K_..."
secret = "S_..."  # pragma: allowlist secret
```

For CI, inject credentials from 1Password or the CI secret store:

```sh
export KOMODO_CLI_HOST='https://komodo.home.example.com'
export KOMODO_CLI_KEY='K_...'
export KOMODO_CLI_SECRET='S_...'  # pragma: allowlist secret
km config
```

Never commit API credentials, place them in ordinary Ansible variables, or
pass them through shell history. Use finite expiry periods for automation keys.

Ansible initially authenticates with the initialization administrator stored
in 1Password. Before enabling two-factor authentication for that user, create
a finite-lived administrator API key, store both values in 1Password, and set
the following references in the ignored `group_vars/all/local.yml`:

```yaml
komodo_onboarding_api_key_secret_reference: op://Turing-Pi/Komodo/bootstrap-api-key
komodo_onboarding_api_secret_secret_reference: op://Turing-Pi/Komodo/bootstrap-api-secret
```

Both references must be configured together. This key is administrator-scoped
because Komodo restricts onboarding-key management to administrators; use it
only for the Ansible bootstrap workflow and rotate it on a finite schedule.

## Install and Enroll Periphery

The normal service play performs the complete Core-first workflow:

1. deploy Traefik, the Postgres/FerretDB database tier, and Komodo Core;
2. wait for the public Komodo endpoint;
3. log in with the initialization administrator from 1Password;
4. create a 30-minute, non-privileged key only when inventory nodes are missing;
5. install the checksum-verified ARM64 Periphery binary serially;
6. connect each agent outbound to Core as its inventory hostname;
7. verify all seven Server resources report `Ok`;
8. create or update `production-swarm` with the three managers;
9. verify Komodo discovers all seven Docker Swarm nodes;
10. disable the onboarding key and remove it from Periphery configuration.

Run it with:

```sh
uv run --frozen ansible-playbook 04-services.yml \
  -i hosts.yml --ask-vault-pass
```

To reconcile only the Komodo enrollment portion against an already healthy
Core and Traefik deployment:

```sh
uv run --frozen ansible-playbook 04-services.yml \
  -i hosts.yml --tags komodo,periphery,onboarding --ask-vault-pass
```

Periphery runs in outbound mode using `core_address` and `connect_as`. The
cluster firewall therefore does not expose `8120/tcp`. Each agent persists its
private key at `/etc/komodo/keys/periphery.key`; the onboarding key is temporary
and is never written to inventory or Git. If the play is interrupted, the key
expires after 30 minutes.

Check the result with:

```sh
km list servers --all --format json
km list swarms --all --format json
```

All seven Servers must be `Ok`. The Komodo Swarm has only `tpi-mgr-01`,
`tpi-mgr-02`, and `tpi-mgr-03` as control endpoints; workers are discovered
through the Docker Swarm API.

## Manual Onboarding Fallback

Ansible is the authoritative onboarding path. For diagnosis, an administrator
can create a one-day key with the CLI:

```sh
umask 077
km create onboarding-key manual-turing-pi \
  --expires 1 --tag prod --tag swarm > onboarding-key.json
chmod 600 onboarding-key.json
```

The CLI prints the private key only once. Do not run Komodo's setup script over
the Ansible-managed binary or service. Pass the private key through an
ephemeral extra variable only for a controlled diagnostic run, then disable it
in Komodo and remove the local file.

Normal enrollment keys are not privileged. If an existing Server has lost its
Periphery private key, review the unexpected key change first, then explicitly
authorize only the affected inventory names:

```sh
uv run --frozen ansible-playbook 04-services.yml -i hosts.yml \
  --tags onboarding,periphery \
  -e '{"komodo_onboarding_rekey_servers":["tpi-wrk-01"],"komodo_onboarding_rekey_confirm":true}' \
  --ask-vault-pass
```

This creates a privileged onboarding key capable of replacing an existing
Server public key. Never enable it fleet-wide as a routine repair.

## Create an API Key

Create a dedicated finite-lived automation key through the API-backed CLI:

```sh
umask 077
km create api-key komodo-day2 --use-api --expires 90 \
  > "$HOME/.config/komodo/day2-key.json"
chmod 600 "$HOME/.config/komodo/day2-key.json"
```

Store the key and secret in 1Password or the CI secret store without printing
the file, then remove the local copy:

```sh
rm -f "$HOME/.config/komodo/day2-key.json"
```

## Create the Resource Sync

The starter declarations are in `komodo-infra/`. Ansible owns `servers.toml`
and `swarm.toml`; exclude those two files from the Day-2 Resource Sync. Create
the first Resource Sync through the Komodo API or UI and select only the Day-2
paths:

1. point it at the repository and intended branch;
2. select `komodo-infra/deployments.toml`, `builds.toml`, `procedures.toml`,
   `variables.toml`, and `stacks/` as resource paths;
3. keep Managed Mode disabled;
4. refresh and review the computed diff;
5. execute manually;
6. repeat several stable syncs;
7. enable a Git webhook only after review is routine.

Remove or replace placeholder resources such as `sample-app`, `backend-api`,
and `frontend` before execution. Keep Server connections, the Swarm resource,
Traefik, the database tier, Komodo Core, Periphery, Keepalived, Swarm secrets,
and infrastructure networks under Ansible ownership.

## Routine CLI Operations

```sh
km config
km --help
km list --help
km create --help
km update --help
km run procedure <procedure-name> -y
km deploy stack <stack-name> -y
km run action <action-name> -y
km ssh <server-name>
km exec <container-name> bash --server <server-name>
```

Persistent Day-2 changes should normally be made in Git and applied through
Resource Sync. Use CLI/API mutations for approved bootstrap, CI/CD, or
break-glass operations and reconcile any intended persistent change to Git.

## Acceptance Checks

```sh
PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" make validate

docker --context tpi service ls | rg 'traefik|komodo|postgres|ferretdb'
curl -k -sS -o /dev/null -w 'komodo=%{http_code}\n' \
  https://komodo.home.example.com/
curl -k -sS -o /dev/null -w 'traefik=%{http_code}\n' \
  https://traefik.home.example.com/ping

km list servers --all --format json
km list swarms --all --format json
```

Expected result of a healthy deployment:

| Check | Expected |
|---|---|
| `docker service ls` | `komodo_postgres`, `komodo_ferretdb`, `komodo_komodo-core` all `1/1`; `traefik_traefik` `3/3` |
| Postgres extensions | `documentdb` and `documentdb_core` both present |
| `km list servers` | all seven `Ok`, Periphery `2.3.2`, `address` empty (outbound mode) |
| `km list swarms` | `production-swarm` `Healthy`, exactly three manager `server_ids` |
| Swarm nodes | seven discovered: three `manager`, four `worker`, all `ready`/`active` |
| Onboarding keys | none enabled |

An empty `address` on every Server is what confirms outbound mode: no node is
listening on `8120`, and the cluster firewall does not open it.

The Swarm lists only the three managers because `server_ids` is a manager
failover pool, not a membership list. Workers are discovered through the Docker
Swarm API and need no entry there.

## Recovery

If Komodo is unavailable, use Ansible and Docker directly. Do not depend on
Komodo to repair its own Core, database tier, Traefik, or Periphery
dependencies.

If a Resource Sync change is wrong, disable its webhook, revert the Git commit,
refresh the sync, review the reverse diff, execute it manually, and verify
application health.

If a CLI/API key is exposed, revoke or expire it, remove it from the secret
store, rotate affected downstream credentials, review audit logs, and create a
replacement key with finite expiry.

If a Periphery key is lost, do not delete all Server resources or automatically
trust the attempted replacement key. Confirm the affected host identity and use
the narrowly scoped privileged re-key procedure above.

## Official References

- [Komodo CLI](https://github.com/moghtech/komodo/blob/main/docsite/docs/ecosystem/cli.mdx)
- [Komodo API and clients](https://github.com/moghtech/komodo/blob/main/docsite/docs/ecosystem/api.md)
- [Komodo server connection setup](https://github.com/moghtech/komodo/blob/main/docsite/docs/setup/connect-servers.mdx)
- [Komodo Resource Sync](https://github.com/moghtech/komodo/blob/main/docsite/docs/automate/sync-resources.md)
- [Komodo configuration reference](https://github.com/moghtech/komodo/blob/main/config/core.config.toml)
- [Komodo Periphery configuration](https://github.com/moghtech/komodo/blob/main/config/periphery.config.toml)
- [Ansible best practices](https://docs.ansible.com/ansible/latest/tips_tricks/ansible_tips_tricks.html)
