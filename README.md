# DietPi Turing Pi Docker Swarm

[![Validate](https://github.com/dannysheehan/turing-pi-docker-swarm/actions/workflows/validate.yml/badge.svg)](https://github.com/dannysheehan/turing-pi-docker-swarm/actions/workflows/validate.yml)

This repository converges seven ARM64 DietPi nodes into a three-manager,
four-worker Docker Swarm. Six nodes use DietPi's Bookworm base and
`tpi-wrk-04` uses DietPi's Trixie base. All seven are full DietPi systems.

The host in the single-member `primary_manager` inventory group is the
administrative endpoint. It must match `swarm_primary_manager` and is not
assumed to be the Raft leader. The expected existing Swarm ID is configured by
`swarm_expected_cluster_id`; it is an identifier, not an authentication

## Ownership boundary

DietPi owns its lifecycle and platform integration:

- first-run setup, update scripts, software catalogue, and service wrapper;
- Docker's official repository, systemd override, iptables backend, cgroups,
  journald driver, and `/mnt/dietpi_userdata/docker-data` integration;
- static `/etc/network/interfaces` configuration;
- DietPi's custom time mode boundary, with Chrony as the Ansible-managed live
  time daemon, and DietPi RAMlog.

Ansible validates those invariants and owns live hostname, timezone, the
managed cluster block in `/etc/hosts`, exact Docker engine package versions,
Swarm membership, NFS, Keepalived, and dedicated firewall chains.
It never rewrites ordinary DietPi networking, edits cgroup boot arguments,
replaces RAMlog, deletes Swarm state, or silently demotes managers.

The template at `templates/dietpi.txt.firstboot.example.j2` is only for
imaging a replacement node. First-boot `AUTO_SETUP_*` values are not used as
live configuration controls. It deliberately uses DietPi time mode 4 until
Ansible switches the live node to custom mode 0 and installs Chrony.

## Controller setup and validation

Create the ignored live inventory and deployment configuration from their
sanitized examples before the first run:

```sh
cp hosts.yml.example hosts.yml
cp group_vars/all/local.yml.example group_vars/all/local.yml
```

Replace every documentation address, cluster ID, NAS path, timezone, and
1Password reference in those local files. Neither live file is intended for
source control.

Use `uv` to create and synchronize the locked controller environment. Ansible
Galaxy remains responsible for the pinned collection because collections are
not Python packages. `ansible.cfg` restricts role and collection discovery to
this repository and stores controller/Galaxy runtime data and connection
sockets under `.ansible/`:

```sh
uv sync --frozen
uv run --frozen ansible-galaxy collection install \
  --collections-path collections \
  -r collections/requirements.yml
make validate
```

After the lock file exists, `make setup` performs the first two commands.
Every validation command runs through `uv run --frozen`, so it cannot silently
resolve newer controller dependencies. Installed Galaxy content lives under
the ignored `collections/ansible_collections/` tree; only the pinned
`collections/requirements.yml` interface is committed.

The validation target parses inventory, syntax-checks every playbook, and runs
the production lint profile. It also runs `detect-secrets` against the intended
public tree and fails on every unallowlisted candidate. SSH host-key checking
remains enabled and SSH pipelining is enabled. Managed nodes use
`/usr/bin/python3` after bootstrap.

## Public repository safety

The live `hosts.yml`, `group_vars/all/local.yml`, encrypted or plaintext
`group_vars/all/vault.yml`, historical infrastructure reviews, controller
runtime files, downloaded collections, environment files, keys, logs, and
backup archives are ignored. Commit the corresponding `.example` files only.

Before the first public commit, run `make validate`, initialize Git, stage the
intended files, and inspect both the file list and staged diff:

```sh
git init
git add .
git status --short
git diff --cached
```

Confirm that `hosts.yml`, `group_vars/all/local.yml`, and
`group_vars/all/vault.yml` do not appear. Never use `git add -f` for an ignored
secret or local configuration file. If a real credential ever enters a commit,
rotate it and remove it from Git history; adding it to `.gitignore` afterward
does not make that commit safe.

## Secrets

For CLI-first Komodo installation, Periphery enrollment, Resource Sync setup,
routine operations, and recovery, see [KOMODO-OPERATIONS.md](KOMODO-OPERATIONS.md).

Application runtime secrets can use 1Password as their source of truth and
native Docker Swarm secrets for delivery. The repository stores only `op://`
references. Ansible retrieves values on the controller with the
`community.general.onepassword` lookup, derives a content hash without writing
the value to disk, normalizes the CLI byte result to UTF-8 text, and creates
immutable Swarm secrets through standard input.

Install and authenticate 1Password CLI on the controller before deploying a
1Password-backed service. For unattended execution, export a least-privilege
service-account token that can read only the automation vault:

```sh
export OP_SERVICE_ACCOUNT_TOKEN='your-controller-or-CI-secret'
```

Unlock 1Password before starting a fleet-wide Ansible run. The repository
allows 60 seconds for SSH and privilege-escalation responses so the 1Password
SSH agent can approve the initial connection batch without Ansible using its
short default timeout.

Never save `OP_SERVICE_ACCOUNT_TOKEN` in this repository, an Ansible variable,
or a Vault file. Store it in the controller keychain or CI secret store.
Secrets are referenced by:

```yaml
komodo_pg_password_secret_reference: op://Automation/Komodo/postgres-password
komodo_admin_username_secret_reference: op://Automation/Komodo/admin-username
komodo_admin_password_secret_reference: op://Automation/Komodo/admin-password
komodo_jwt_secret_reference: op://Automation/Komodo/jwt-secret
# Optional administrator API credentials for unattended onboarding after 2FA:
komodo_onboarding_api_key_secret_reference: op://Automation/Komodo/bootstrap-api-key
komodo_onboarding_api_secret_secret_reference: op://Automation/Komodo/bootstrap-api-secret
```

These are examples; put the real references only in the ignored
`group_vars/all/local.yml` file.

Komodo local authentication is enabled by default. On a fresh deployment, Core
creates the initial administrator from the configured username and password, so
`komodo_disable_user_registration` can remain `true` from the first run. Create
these additional 1Password fields before the first Komodo deployment:

- `admin-username`: 3-64 characters from letters, numbers, `.`, `_`, or `-`.
- `admin-password`: at least 20 characters.
- `jwt-secret`: at least 32 characters; use a randomly generated value.
- `postgres-password`: 20-128 **alphanumeric** characters. It is embedded
  verbatim in the FerretDB `postgres://` connection URL, so symbols and
  whitespace would corrupt it.

The username is passed as non-secret initialization configuration because it
is not credential material. The password and JWT secret are synchronized as
Swarm secrets. After the first successful login, keep the admin password and
JWT secret in 1Password; do not place either value in the stack file.

The Komodo database is FerretDB v2 over Postgres 17 with the DocumentDB
extension. MongoDB 5.0+ requires ARMv8.2-A LSE atomics, which the Cortex-A53 in
a CM3+ does not implement, so stock MongoDB is permanently capped at the
end-of-life 4.4 series on this hardware; FerretDB is the path Komodo documents
for exactly that case. It also replaces a three-member replica set with a
single Postgres instance, which matters on 955MB nodes.

The Postgres password is synchronized as the immutable Swarm secret
`komodo_pg_password_<sha256-prefix>`. Komodo Core reads it from
`/run/secrets/komodo_pg_password` through `KOMODO_DATABASE_PASSWORD_FILE`, and
FerretDB reads a derived connection URL from `/run/secrets/komodo_ferretdb_url`
through `FERRETDB_POSTGRESQL_URL_FILE`. Neither value is rendered into the
service environment or the stack file.

Rotating this password is not a matter of editing 1Password alone.
`POSTGRES_PASSWORD` is only read when the entrypoint initialises an empty data
directory, so changing the 1Password value on a running cluster rotates the
Swarm secret and the FerretDB URL but leaves the database credential unchanged,
and Core then fails to authenticate. Change it with `ALTER ROLE` inside
Postgres first; see the rotation procedure in `KOMODO-OPERATIONS.md`.

Periphery is deployed by Ansible to all seven nodes as a checksum-verified,
systemd-managed ARM64 binary. Each agent connects outbound to Komodo Core, so
port 8120 is not exposed by the cluster firewall. Run the complete Core-first
enrollment flow with:

```sh
uv run --frozen ansible-playbook 04-services.yml \
  -i hosts.yml --tags komodo,periphery,onboarding --ask-vault-pass
```

Ansible logs in with the initialization administrator, creates a 30-minute
non-privileged onboarding key only for missing inventory hosts, enrolls the
agents serially, verifies all connections, and disables the key. The temporary
key is protected with `no_log`, removed from each Periphery configuration, and
never committed. Periphery retains its own private key under
`/etc/komodo/keys`. Ansible then creates or updates the Komodo Swarm with only
the three manager Server resources and verifies that Komodo discovers all seven
Docker nodes. Keep `komodo-infra/` in Resource Sync review mode until several
manual syncs have been verified.

Native Swarm secrets remain encrypted in the replicated Raft log and available
to scheduled tasks when 1Password is unavailable. A new convergence or secret
rotation still requires controller access to 1Password.

Host-level operational secrets that are not consumed by Swarm services remain
in Ansible Vault. Create the automatically loaded Vault file from the
non-loaded example, replace every placeholder, and encrypt it before running a
Vault-dependent playbook:

```sh
cp group_vars/all/vault.yml.example group_vars/all/vault.yml
uv run --frozen ansible-vault encrypt group_vars/all/vault.yml
```

The repository intentionally ignores `group_vars/all/vault.yml`, including its
encrypted form, to avoid publishing ciphertext for offline password attacks.
Never commit its plaintext form or a Vault password file. Its decrypted
variables are:

```yaml
vault_keepalived_auth_pass: exactly8
vault_backup_passphrase: a-long-random-backup-encryption-passphrase
```

The VRRP password must be exactly eight characters. The backup passphrase must
be at least 20 characters. Secret-bearing tasks use `no_log`.

## Supported playbooks

`site.yml` is the normal convergence entry point. The numbered component
playbooks it imports remain available for scoped repair and diagnosis; they
are not an alternative rollout sequence.

| Interface | Use |
|---|---|
| `site.yml` | Normal runtime preparation and convergence of an existing Swarm |
| `00-preflight.yml` | Read-only DietPi and host prerequisite validation |
| `01-provision.yml` through `04-services.yml` | Targeted baseline, Docker, Swarm, or service reconciliation |
| `03-swarm-bootstrap.yml` | Explicit, one-time initialization of a genuinely new Swarm |
| `05-os-maintenance.yml` | Explicit rolling DietPi/OS maintenance |
| `08-firewall.yml` | Explicit serial firewall activation |
| `96-komodo-teardown.yml` | Destructive, confirm-gated removal of Komodo and all of its database state |
| `97-swarm-restore.yml` | Destructive, highly guarded Raft-state restoration |
| `98-swarm-backup.yml` | Operator-requested encrypted Swarm backup |
| `99-reboot-kernel.yml` | Emergency reboot of exactly one limited node |

`04-services.yml` exposes `nfs`, `keepalived`, `traefik`, `database`,
`periphery`, `onboarding`, and `komodo` tags for a scoped operator
convergence. Use `--tags database` to reconcile only the Postgres/FerretDB
tier and Komodo Core, or `--tags komodo` for the whole control plane including
Periphery enrollment and the Swarm resource.

`site.yml` does not perform OS upgrades, firewall
activation, first Swarm initialization, Swarm backup/restore, or emergency
reboots.

## First Swarm initialization

Normal convergence requires `swarm_primary_manager` to belong to the recorded
Swarm. It deliberately refuses to initialize an inactive manager: Docker
generates a random cluster ID, so initialization cannot safely satisfy a
preconfigured `swarm_expected_cluster_id` guard.

For a genuinely new cluster, leave `swarm_expected_cluster_id` empty or set to
the example placeholder and run the dedicated operator playbook:

```sh
uv run --frozen ansible-playbook 03-swarm-bootstrap.yml \
  -e swarm_first_init=true \
  -e swarm_init_confirm=INITIALIZE-NEW-SWARM
```

The play refuses check mode, requires all seven nodes to be inactive, and
never removes Swarm state. Record the generated ID it prints in the ignored
`group_vars/all/local.yml`, then run `03-swarm-init.yml` or `site.yml` to join
the other managers and workers. Do not use first initialization after state
loss; restore the encrypted Swarm backup so the recorded cluster identity is
preserved.

The completed NFS-to-local migration playbook has been removed. It
targeted the retired HTTP-9000/NFS deployment and must not be rerun against
the current encrypted local database. The retained NFS data and encrypted
archives are rollback artifacts, not active application storage.

## Normal convergence

1. Run `make validate`.
2. Run the read-only preflight with
   `uv run --frozen ansible-playbook 00-preflight.yml --ask-vault-pass`.
3. Create and validate a current Swarm backup before disruptive
   maintenance.
4. Run `uv run --frozen ansible-playbook site.yml --ask-vault-pass`.
5. Review the recap, then run `site.yml` again to verify idempotence.
6. Apply the firewall separately, only from inside `admin_cidr` with console
   access available:

   ```sh
   uv run --frozen ansible-playbook 08-firewall.yml \
     -e firewall_confirm=true --ask-vault-pass
   ```

Normal `site.yml` convergence requires the Keepalived and backup secrets when
those services are enabled.

## Maintenance and recovery

General maintenance holds `docker-ce` and `docker-ce-cli`, drains each node,
runs `/boot/dietpi/dietpi-update 1`, applies an APT dist-upgrade, reboots only
when required, and checks DietPi postboot, Docker, Chrony synchronization, and
Swarm before restoring the original availability. It requires explicit
operator confirmation:

```sh
uv run --frozen ansible-playbook 05-os-maintenance.yml \
  -e os_maintenance_confirm=true --ask-vault-pass
```

Use `--limit` to prove the workflow on one worker before expanding it. This is
ordinary release maintenance; it does not upgrade a Bookworm node to Trixie.

The updater wrapper watches DietPi's update log. Only after incremental
patching has completed does it terminate a descendant `whiptail`, selecting
DietPi's skip-reboot path so DietPi restarts services and returns its real exit
status. A 30-minute timeout leaves the updater and package processes alone and
requires operator inspection. It never kills `dpkg` or the updater process.

Create an encrypted Swarm backup with:

```sh
uv run --frozen ansible-playbook 98-swarm-backup.yml \
  -e swarm_backup_confirm=true --ask-vault-pass
```

This requires three healthy managers, stops Docker only on
`swarm_primary_manager`, archives the complete configured `swarm` directory,
validates the encrypted archive, always restarts Docker, and retains the newest
eight archives plus metadata.

Restoration is destructive and guarded by the exact cluster ID:

```sh
uv run --frozen ansible-playbook 97-swarm-restore.yml \
  -e swarm_restore_archive=/srv/nfs/backups/swarm/swarm-TIMESTAMP.tar.gz.enc \
  -e swarm_restore_confirm='RESTORE-<expected-cluster-id>' \
  --ask-vault-pass
```

The play validates the archive before stopping managers, preserves the current
primary state for rollback, restores Raft state, and forces a new quorum. It
does not erase or automatically demote manager state. If former managers do
not reconnect cleanly, stop and follow Docker's manager recovery procedure
rather than deleting state ad hoc.

## Network and availability limits

The firewall owns only `ANSIBLE-INPUT` and leaves
DietPi/Docker-generated rules intact. It trusts peer-only Swarm ports
2377/tcp, 7946/tcp+udp, and 4789/udp; manager-only VRRP protocol 112; and LAN
SSH access. VXLAN must never be exposed to an untrusted network.

Keepalived derives its interface, `/24` VIP, priorities, and unicast peers from
inventory and tracks local Docker/manager health. All three managers remain in
the same Turing Pi chassis, switch, and power failure domain, so three-manager
Raft quorum does not protect against chassis, switch, or power loss. Swarm
autolock stays disabled for unattended power recovery; encrypted backups are
the recovery control.
