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

## Rotating the Postgres Password

`POSTGRES_PASSWORD` is only consulted when the Postgres entrypoint initialises
an empty data directory. Changing the 1Password value on a running cluster
therefore rotates the Swarm secret and the FerretDB connection URL, but **not**
the password inside the existing database, and Komodo Core will fail to
authenticate on its next restart.

To rotate safely, change it inside Postgres first, then let Ansible catch up:

```sh
cid=$(docker ps --quiet --filter 'name=komodo_postgres\.1\.' | head -n1)
docker exec -it "$cid" psql -U komodo_user -d postgres \
  -c "ALTER ROLE komodo_user WITH PASSWORD '<new-value>';"  # pragma: allowlist secret
```

Then update `postgres-password` in 1Password to the same value and re-run the
`database` tag. The value must be 20-128 alphanumeric characters: it is
embedded verbatim in the FerretDB `postgres://` URL, so reserved URL
characters would corrupt the connection string. The role asserts this.

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
