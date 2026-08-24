# DietPi Turing Pi Docker Swarm

[![Validate](https://github.com/dannysheehan/turing-pi-docker-swarm/actions/workflows/validate.yml/badge.svg)](https://github.com/dannysheehan/turing-pi-docker-swarm/actions/workflows/validate.yml)

This repository converges seven ARM64 DietPi nodes into a three-manager,
four-worker Docker Swarm. Six nodes use DietPi's Bookworm base and
`tpi-wrk-04` uses DietPi's Trixie base. All seven are full DietPi systems.

The host in the single-member `primary_manager` inventory group is the
administrative endpoint. It must match `swarm_primary_manager` and is not
assumed to be the Raft leader. The expected existing Swarm ID is configured by
`swarm_expected_cluster_id`; it is an identifier, not an authentication
secret. `portainer_primary_manager` derives from `swarm_primary_manager`, so
Portainer follows the same explicitly selected administrative manager.

## Ownership boundary

DietPi owns its lifecycle and platform integration:

- first-run setup, update scripts, software catalogue, and service wrapper;
- Docker's official repository, systemd override, iptables backend, cgroups,
  journald driver, and `/mnt/dietpi_userdata/docker-data` integration;
- static `/etc/network/interfaces` configuration;
- `systemd-timesyncd` mode 4 and DietPi RAMlog.

Ansible validates those invariants and owns live hostname, timezone, the
managed cluster block in `/etc/hosts`, exact Docker engine package versions,
Swarm membership, NFS, Portainer, Keepalived, and dedicated firewall chains.
It never rewrites ordinary DietPi networking, edits cgroup boot arguments,
replaces RAMlog, deletes Swarm state, or silently demotes managers.

The template at `templates/dietpi.txt.firstboot.example.j2` is only for
imaging a replacement node. First-boot `AUTO_SETUP_*` values are not used as
live configuration controls.

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
op read 'op://Automation/Portainer/database-key' >/dev/null
```

Never save `OP_SERVICE_ACCOUNT_TOKEN` in this repository, an Ansible variable,
or a Vault file. Store it in the controller keychain or CI secret store. The
Portainer database key must be exactly 32 printable ASCII characters and is
referenced by:

```yaml
portainer_database_secret_reference: op://Automation/Portainer/database-key
portainer_backup_secret_reference: op://Automation/Portainer/backup-passphrase
```

These are examples; put the real references only in the ignored
`group_vars/all/local.yml` file.

The resulting Swarm object is named
`portainer_database_key_<sha256-prefix>` and labelled with its full content
hash. Portainer receives it at `/run/secrets/portainer`. After the updated
server task, all agents, mounted secret reference, and HTTPS status endpoint
are healthy, Ansible removes older unused managed versions.

Adding this key to an existing Portainer installation encrypts its database
and is irreversible. Before the first deployment, verify both an encrypted
Portainer backup and the ability to retrieve the exact 1Password item. Do not
delete or rotate that item independently of an Ansible deployment: Portainer
cannot start an encrypted database with the wrong key. Unlike ordinary Swarm
credentials, this database key cannot be rotated by merely replacing the
secret. The role detects a changed key and fails before altering the running
service; rotation requires a separately designed Portainer re-key procedure.
The first encryption of an existing database is deliberately blocked unless
the operator supplies the one-time acknowledgement:

```sh
uv run --frozen ansible-playbook 04-services.yml \
  -e portainer_database_encryption_confirm=true --ask-vault-pass
```

Subsequent convergences detect the secret already mounted by the service and
do not require this acknowledgement.

Native Swarm secrets remain encrypted in the replicated Raft log and available
to scheduled tasks when 1Password is unavailable. A new convergence or secret
rotation still requires controller access to 1Password.

Portainer's unattended backup passphrase is a separate 1Password field. It is
resolved during convergence and installed as a root-only host file because the
systemd backup job runs independently of Swarm. It must never reuse the
database-encryption key.

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
vault_portainer_admin_password: an-optional-initial-password
```

The VRRP password must be exactly eight characters. The backup passphrase must
be at least 20 characters. The Portainer administrator password is used only
by the explicitly enabled fresh-install initialization play. Secret-bearing
tasks use `no_log`.

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
| `06-portainer-setup.yml` | One-time, token-aware creation of a fresh Portainer administrator |
| `08-firewall.yml` | Explicit serial firewall activation |
| `97-swarm-restore.yml` | Destructive, highly guarded Raft-state restoration |
| `98-swarm-backup.yml` | Operator-requested encrypted Swarm backup |
| `99-portainer-restart.yml` | Rolling Portainer server restart or fresh setup-window reset |
| `99-reboot-kernel.yml` | Emergency reboot of exactly one limited node |

`04-services.yml` exposes `nfs`, `keepalived`, and `portainer` tags for a
scoped operator convergence, for example `--tags portainer`.

`site.yml` does not perform OS upgrades, Portainer data migration, firewall
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

The completed NFS-to-local Portainer migration playbook has been removed. It
targeted the retired HTTP-9000/NFS deployment and must not be rerun against
the current encrypted local database. The retained NFS data and encrypted
archives are rollback artifacts, not active application storage.

## Normal convergence

1. Run `make validate`.
2. Run the read-only preflight with
   `uv run --frozen ansible-playbook 00-preflight.yml --ask-vault-pass`.
3. Create and validate current Portainer and Swarm backups before disruptive
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
those services are enabled. Set `portainer_enabled: false` to omit every
Portainer deployment and backup action.

## Portainer architecture and initial setup

Portainer CE 2.39.6 runs as one server replica pinned to the host selected by
`primary_manager`, with a global agent on all seven nodes. Agents use a private
overlay and the server connects to `tasks.agent:9001`. Only HTTPS 9443 is
published; 9000 and 8000 are not published. Updates and rollbacks are
one-at-a-time and stop-first. Its
database-encryption key is synchronized from 1Password into a versioned native
Swarm secret and mounted only into the server task.

The agent mounts DietPi's actual Docker volume store from
`{{ docker_data_root }}/volumes` to the vendor-required in-container path
`/var/lib/docker/volumes`; it does not assume Debian's default host path.

The encrypted database is stored at
`/mnt/dietpi_userdata/portainer-data` on `portainer_primary_manager`, not NFS.
Ordinary convergence refuses to move or initialize data implicitly.

Portainer 2.39 generates an ephemeral setup token when no administrator exists.
The token is a short-lived bootstrap credential written to the server task log;
it is not the 1Password database key and must not be committed or saved as a
long-lived secret.

For automatic initialization, put `vault_portainer_admin_password` in the
encrypted Vault file, temporarily set `portainer_auto_setup: true`, then run:

```sh
uv run --frozen ansible-playbook 06-portainer-setup.yml --ask-vault-pass
```

The play opens a fresh setup window, reads the token with `no_log`, sends it in
the `X-Setup-Token` header, creates the administrator, and verifies completion.
Set `portainer_auto_setup` back to `false` afterward.

For manual browser setup, restart the server and print the newest token only to
your terminal:

```sh
make portainer-restart
make portainer-setup-token
```

Paste the 64-character result into Portainer's **Setup token** field and finish
within five minutes. If it expires, repeat both commands. The helper reads the
token in memory and does not write it to the repository or a temporary file.
See Portainer's [initial setup](https://docs.portainer.io/start/install/server/setup)
and [setup timeout](https://docs.portainer.io/faqs/installing/your-portainer-instance-has-timed-out-for-security-purposes-error-fix)
documentation for the vendor workflow.

The daily 03:30 backup verifies NFS, scales the server to zero, encrypts and
validates the local data archive, restores the replica through a shell trap,
and removes successful archives older than 14 days.

The NAS export uses root squash, so NFS objects are owned by the NAS-mapped
account rather than Linux root. Ansible enforces restrictive modes and
writability but does not attempt an invalid `chown root` across the NFS
boundary. NAS-side ownership and ACL policy remain owned by the NAS.

## Maintenance and recovery

General maintenance holds `docker-ce` and `docker-ce-cli`, drains each node,
runs `/boot/dietpi/dietpi-update 1`, applies an APT dist-upgrade, reboots only
when required, and checks DietPi postboot, Docker, time sync, and Swarm before
restoring the original availability.

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

The firewall owns only `ANSIBLE-INPUT` and `ANSIBLE-PORTAINER` and leaves
DietPi/Docker-generated rules intact. It trusts peer-only Swarm ports
2377/tcp, 7946/tcp+udp, and 4789/udp; manager-only VRRP protocol 112; and LAN
SSH/Portainer access. VXLAN must never be exposed to an untrusted network.

Keepalived derives its interface, `/24` VIP, priorities, and unicast peers from
inventory and tracks local Docker/manager health. All three managers remain in
the same Turing Pi chassis, switch, and power failure domain, so three-manager
Raft quorum does not protect against chassis, switch, or power loss. Swarm
autolock stays disabled for unattended power recovery; encrypted backups are
the recovery control.
