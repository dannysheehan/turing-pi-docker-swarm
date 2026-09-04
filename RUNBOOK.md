# Failure Recovery Runbook

What recovers on its own, what does not, and what to do about the second
category. Read the triage section first; it tells you which scenario you are in.

Placeholders: `<komodo-domain>` is the Komodo hostname, `<db-host>` the external
PostgreSQL host, `<nas>` the NFS server. Real values are in the ignored
`group_vars/all/local.yml`.

## The short answer

**A single manager failure needs no intervention.** Swarm keeps quorum on the
remaining two, Keepalived moves the VIP, Traefik keeps serving on the survivors,
and Komodo reschedules itself onto any healthy node.

**Losing two of three managers does need intervention**, and so do the four
shared dependencies listed under [What is not automatic](#what-is-not-automatic).

Komodo's automatic failover is recent. Until 2026-09-04 the control plane was
pinned to one node and a node failure meant an outage until a human moved it.
That is no longer true, and it was verified rather than assumed: Core ran on
`tpi-wrk-03`, `tpi-mgr-01` and `tpi-wrk-01` on 2026-09-04 and reported the same
public key each time, because its keypair lives on NFS rather than on a node.

## Triage

Run these three first. They place you in a scenario without guessing.

```sh
# 1. Is the Swarm healthy, and does it still have quorum?
ssh <any-manager> 'docker node ls'

# 2. Is the Komodo control plane scheduled and running?
ssh <any-manager> 'docker stack ps komodo --filter desired-state=running \
  --format "{{.Name}} | {{.Node}} | {{.CurrentState}} | {{.Error}}"'

# 3. Is the site actually serving?
curl -sk -o /dev/null -w '%{http_code}\n' https://<komodo-domain>/
```

Read them together:

| `docker node ls` | Komodo tasks | Scenario |
|---|---|---|
| one node `Down`, others `Ready` | `Running` | [1 — single node lost](#scenario-1-a-single-node-is-lost) (no action) |
| two managers `Down` or command hangs | any | [2 — quorum lost](#scenario-2-quorum-is-lost) |
| all `Ready` | `Pending` | [3 — cannot schedule](#scenario-3-komodo-cannot-schedule) |
| all `Ready` | restarting / `Failed` | [4 — Komodo crash loop](#scenario-4-komodo-is-crash-looping) |
| a node returns after a failure | any | [5 — node rejoining](#scenario-5-a-failed-node-rejoins) |

A `docker node ls` that hangs rather than answers is itself the diagnosis: the
manager you asked has no quorum to answer from. Go to scenario 2.

## What is not automatic

Five things. The first is the serious one; the rest are shared dependencies
that the 2026-09-04 migration introduced or exposed.

1. **Quorum loss.** Two managers down out of three freezes the Swarm. Running
   services keep running, but nothing can be scheduled, changed, or recovered
   until quorum is restored by hand.
2. **The NAS.** Core's keypair (`/config`) and all backups live there. If the
   NAS is unreachable Core cannot start *on any node* — the failure moved from
   one node to one NAS. This is a deliberate trade: one shared dependency in
   exchange for free rescheduling.
3. **The external database.** If `<db-host>` is unreachable Core exits at
   startup and restarts forever. Nothing in the cluster can fix it.
4. **A rebuilt or reflashed node.** It comes back without the IPsec ESP firewall
   rules, and anything scheduled onto it that needs the encrypted overlay fails
   silently. See [scenario 5](#scenario-5-a-failed-node-rejoins).
5. **Core's identity.** If `/config/keys/core.key` is lost or shadowed, every
   Periphery agent refuses to log in. See
   [Core identity lost](#core-identity-lost).

## Scenario 1: a single node is lost

**No action required.** Confirm and move on.

```sh
ssh <surviving-manager> 'docker node ls; docker service ls'
curl -sk -o /dev/null -w '%{http_code}\n' https://<komodo-domain>/
```

Expected within a few minutes:

- `docker node ls` shows the node `Down`, quorum intact on the other two
  managers, one of which is `Leader`.
- Komodo `ferretdb` and `komodo-core` are `Running` on other nodes.
- The site returns `200`.
- Komodo shows the lost node as `NotOk` and the rest `Ok`. That is correct
  reporting, not a fault.

If the lost node was a **manager**, one expected degradation: Traefik is
constrained to `node.role == manager` with three replicas, so it drops to `2/3`
with one task `Pending` until a third manager returns. Two replicas serve fine.
Do not "fix" this by reducing replicas unless the manager is gone for good.

The VIP moves on its own. Keepalived runs `check-swarm-manager`, which requires
`Swarm.ControlAvailable = true`, so a node that is down or is no longer a
manager removes itself from VIP contention. Combined with `nopreempt`, a
returning manager does not steal the VIP back.

## Scenario 2: quorum is lost

Two of three managers are down. Symptoms: `docker node ls` hangs or reports
`rpc error ... context deadline exceeded`; no service can be updated.

Running containers keep running throughout. Resist the urge to reboot things.

**First, try to bring a manager back.** Restoring the third manager is always
preferable to forcing a new cluster, and usually faster.

```sh
ping <manager-ip>
ssh <manager> 'systemctl status docker; journalctl -u docker -n 50 --no-pager'
```

If a manager can be revived, quorum returns on its own and there is nothing
further to do.

**If it cannot**, force a new single-manager cluster from the survivor. This is
destructive to Raft membership and demotes the other managers:

```sh
ssh <surviving-manager> 'docker swarm init --force-new-cluster'
ssh <surviving-manager> 'docker node ls'
```

Then promote replacements back to three managers once they are rebuilt:

```sh
ssh <surviving-manager> 'docker node promote <node>'
```

**If Raft state itself is damaged**, use the guarded restore playbook rather
than hand-editing state. It validates the archive before stopping anything,
preserves the current state for rollback, and forces the new quorum for you:

```sh
uv run --frozen ansible-playbook 97-swarm-restore.yml \
  -e swarm_restore_archive=/srv/nfs/backups/swarm/swarm-TIMESTAMP.tar.gz.enc \
  -e swarm_restore_confirm='RESTORE-<expected-cluster-id>' \
  --ask-vault-pass
```

**Know what the restore costs you before running it.** Swarm backups are
operator-triggered, not scheduled, so the archive is usually old. Restoring
rolls service definitions back to the archive date — which can reinstate a
superseded stack. After any restore, re-run the service playbooks to bring
definitions back to the committed state:

```sh
uv run --frozen ansible-playbook 04-services.yml --ask-vault-pass
```

Take a fresh Swarm backup whenever the topology changes — after promoting,
demoting, or replacing a manager:

```sh
uv run --frozen ansible-playbook 98-swarm-backup.yml \
  -e swarm_backup_confirm=true --ask-vault-pass
```

## Scenario 3: Komodo cannot schedule

Nodes are `Ready` but tasks sit `Pending`. Read the error:

```sh
ssh <manager> 'docker service ps komodo_komodo-core --no-trunc \
  --format "{{.CurrentState}} | {{.Error}}"'
```

`no suitable node (scheduling constraints not satisfied ...)` means something
reintroduced a placement constraint. Neither Komodo service should have one:

```sh
ssh <manager> 'docker service inspect komodo_komodo-core \
  --format "{{json .Spec.TaskTemplate.Placement.Constraints}}"'   # expect: null
```

If it is not `null`, redeploy from the committed stack:

```sh
uv run --frozen ansible-playbook 04-services.yml --tags komodo --ask-vault-pass
```

`no suitable node (insufficient resources)` is different — the cluster is full.
These are 1 GB nodes; check memory before blaming the scheduler.

## Scenario 4: Komodo is crash looping

Tasks start and fail repeatedly. Get the reason:

```sh
ssh <manager> 'docker service logs komodo_komodo-core --tail 40 2>&1 | tail -15'
```

**`Failed to initialize database::Client ... Server selection timeout`** — Core
cannot reach FerretDB. Two distinct causes:

*The database host is unreachable.* Check first, since it is outside the
cluster:

```sh
ssh <manager> 'timeout 5 bash -c "cat </dev/null >/dev/tcp/<db-host>/5432" \
  && echo OPEN || echo UNREACHABLE'
```

*The encrypted overlay is broken between the two nodes.* This one is
deceptive — DNS keeps working while the data plane is dead, because DNS rides
the 7946 control plane and the data plane is IPsec ESP:

```sh
ssh <node-running-core> 'docker run --rm --network komodo_back busybox \
  sh -c "nslookup ferretdb; nc -z -w 8 ferretdb 27017 && echo OPEN || echo CLOSED"'
```

`ferretdb` resolving but the port `CLOSED` is the ESP signature. Fix:

```sh
ssh <node> 'sudo iptables -S ANSIBLE-INPUT | grep -c "p esp"'   # expect 6
uv run --frozen ansible-playbook 08-firewall.yml \
  -e firewall_confirm=true --ask-vault-pass
```

**`permission denied for table ...`** — a database-side grant regressed.
`komodo_db_user` must be a member of `documentdb_admin_role`; individual table
grants are never sufficient, because DocumentDB creates a table per collection
at runtime. This one belongs to whoever owns `<db-host>`.

## Scenario 5: a failed node rejoins

The riskiest routine event, because a returning node carries stale state that
silently overrides current configuration. Do this **before** letting workloads
schedule onto it.

```sh
# 1. Keep it out of the way while you work.
ssh <manager> 'docker node update --availability drain <node>'
```

```sh
# 2. Remove stale node-local volumes. Docker matches volumes by NAME, so a
#    leftover local volume shadows the NFS definition of the same name and Core
#    would boot from a stale /config with a retired identity.
ssh <node> 'sudo docker volume ls --format "{{.Name}}" | grep -i komodo'
ssh <node> 'sudo docker volume rm komodo_komodo_config komodo_komodo_pg_data'
```

If removal reports the volume is in use, an exited container from the original
failure is holding it. Remove the orphan, then the volume:

```sh
ssh <node> 'sudo docker ps -a --filter volume=komodo_komodo_config \
  --format "{{.ID}} {{.Names}} {{.Status}}"'
ssh <node> 'sudo docker rm <container-id>'
```

Keep `komodo_komodo_backups` — it is an NFS volume and matches the current
stack definition.

```sh
# 3. Firewall. A node that was down during a firewall run has no ESP rules, and
#    an unpatched node breaks anything using the encrypted overlay.
ssh <node> 'sudo iptables -S ANSIBLE-INPUT | grep -c "p esp"'         # live
ssh <node> 'sudo grep -c "p esp" /usr/local/sbin/ansible-swarm-firewall'  # persisted
uv run --frozen ansible-playbook 08-firewall.yml \
  -e firewall_confirm=true --ask-vault-pass
```

Check both numbers. Rules can be live but not persisted, in which case they
vanish on the next reboot.

```sh
# 4. Prove the encrypted overlay works from the node before trusting it.
ssh <manager> 'docker node update --availability active <node>'
ssh <node> 'sudo docker run --rm --network komodo_back busybox \
  sh -c "nc -z -w 8 ferretdb 27017 && echo OPEN || echo CLOSED"'
```

```sh
# 5. Promote it back, if it was a manager. This restores 3-manager quorum and
#    lets Traefik reach 3/3 again.
ssh <manager> 'docker node promote <node>'
```

```sh
# 6. Re-enroll its Periphery agent. A node that was down during a Core identity
#    change still pins the retired key. See below.
```

Finally, take a fresh Swarm backup — the topology changed.

## Core identity lost

Symptom: every agent reports `NotOk`, and their logs say:

```text
Periphery failed to validate Core public key: ... is invalid
```

Core generates a fresh keypair whenever `/config/keys/core.key` is missing, and
Periphery **pins** the first Core key it sees. After a Core identity change no
agent will log in.

The mismatch is usually **mutual**, and fixing one direction is not enough:
agents rotate their own keys on a schedule, so a database restored from a backup
older than the last rotation also holds stale Periphery keys.

Per affected node:

```sh
ssh <node> 'sudo systemctl stop periphery && sudo rm -rf /etc/komodo/keys \
  && sudo systemctl start periphery'
```

The agent then generates a new keypair, learns the current Core key, and offers
itself for approval. Core records the offer as `attempted_public_key` and
refuses the login until an admin approves it.

**Verify the offered key against the agent's disk before approving.** Do not
trust the database value alone — that check is the whole security of the step:

```sh
ssh <node> 'sudo cat /etc/komodo/keys/periphery.pub'   # compare to attempted_public_key
```

Approve in the UI, or via the API with `UpdateServerPublicKey`. Agents return to
`Ok` within about 20 seconds.

## NAS unreachable

Core cannot start anywhere: `/config` (its keypair) and `/backups` are both NFS.

```sh
ssh <manager> 'timeout 5 bash -c "cat </dev/null >/dev/tcp/<nas>/2049" \
  && echo OPEN || echo UNREACHABLE'
```

Restore the NAS. Do **not** work around it by recreating `/config` locally: that
gives Core a fresh identity and locks out every agent, converting an outage into
a re-enrollment. FerretDB is unaffected — it is stateless and talks only to the
external database.

## Verifying a recovery

Do not stop at "the site loads". Check all four:

```sh
# Swarm: all nodes Ready, three managers, one Leader
ssh <manager> 'docker node ls'

# Services: ferretdb 1/1, komodo-core 1/1, traefik 3/3
ssh <manager> 'docker service ls'

# Every Traefik replica proxies to Core, not just the one behind the VIP
for m in <manager-ips>; do
  curl -sk -o /dev/null -w "$m -> %{http_code}\n" -H 'Host: <komodo-domain>' https://$m/
done

# Agents: all servers Ok in Komodo
```

The strongest single check is triggering the **Backup Core Database** procedure
and confirming a new dated folder appears on the NAS. It exercises Core, the
external database, and NFS in one action.

Backup folder names are **UTC**; the NAS shows local mtimes. A "missing" 01:00
backup is usually just a timezone confusion — check the current UTC time before
raising an alarm.

## Known gaps

- **Swarm backups are operator-triggered, not scheduled.** The newest archive is
  typically weeks old and predates recent topology changes. Run
  `98-swarm-backup.yml` after any manager promotion, demotion or replacement.
- **Two managers tolerate zero failures.** Three tolerate one. If a manager is
  demoted or removed, restoring the third is a priority, not housekeeping.
- **The NAS and the external database are both single points of failure** for
  Komodo Core. Neither is redundant. This is an accepted trade for removing the
  node-pinning that caused the 2026-09-04 outage, but it should be a conscious
  one.
- **Root cause of the 2026-09-04 node failure is unknown.** The node stayed on
  the network while every disk read failed. Its eMMC reported healthy
  afterwards, so it may recur. Node logs are forwarded to the NAS syslog
  receiver; local journald is volatile and keeps nothing across a reboot.
