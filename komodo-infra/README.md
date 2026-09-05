# Komodo Resource Sync Starter

This folder is a starter skeleton for Komodo GitOps Resource Sync.

Usage:

1. Create a new Resource Sync in Komodo.
2. Select `deployments.toml`, `builds.toml`, `procedures.toml`,
   `variables.toml`, and `stacks/` as resource paths.
3. Start with Managed Mode disabled.
4. Refresh, review, and execute changes manually.
5. Enable webhook sync only after a few stable manual cycles.

Notes:

- Replace placeholder values before first production deploy.
- Do not store sensitive values in Git. Use your secret manager and Komodo
  variables.
- Server and Swarm resources are **not** declared here. Ansible creates them
  through the Komodo API from `hosts.yml`, so the inventory is their single
  source of truth. Earlier revisions carried `servers.toml` and `swarm.toml`;
  they were removed because nothing read them and editing them had no effect.
- Keep control-plane bootstrap resources (Traefik, FerretDB, Komodo Core,
  Periphery) under Ansible ownership. PostgreSQL is not in this cluster at all;
  it runs on an external host that Ansible does not manage.
