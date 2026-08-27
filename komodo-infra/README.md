# Komodo Resource Sync Starter

This folder is a starter skeleton for Komodo GitOps Resource Sync.

Usage:
1. Create a new Resource Sync in Komodo.
2. Point resource path at `komodo-infra/`.
3. Start with Managed Mode disabled.
4. Refresh, review, and execute changes manually.
5. Enable webhook sync only after a few stable manual cycles.

Notes:
- Replace placeholder values before first production deploy.
- Do not store sensitive values in Git. Use your secret manager and Komodo variables.
- Keep core control-plane bootstrap resources (Traefik bootstrap, Mongo replica bootstrap) under Ansible ownership.
