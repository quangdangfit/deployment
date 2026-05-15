# Rotate credentials

## App secrets (Doppler-backed)

1. Generate the new value (e.g., `openssl rand -hex 32`).
2. Update the Doppler key in BOTH `dev` and `prod`.
3. ESO will pick up within `refreshInterval` (1h). To force immediate refresh:
   ```bash
   kubectl -n goshop annotate externalsecret goshop-secrets force-sync=$(date +%s) --overwrite
   ```
4. Restart the deployment so pods reload env:
   ```bash
   kubectl -n goshop rollout restart deploy/goshop
   ```

## Postgres password

The Bitnami chart cannot rotate `postgres-password` in place — it's used by the init job.
To rotate the **app** user password (`POSTGRES_PASSWORD`):

```bash
kubectl -n data exec -it postgresql-0 -- \
  psql -U postgres -c "ALTER USER goshop WITH PASSWORD '<new>';"
# update DATABASE_URI in Doppler with the new password
# force-sync ESO + restart goshop (see above)
```

## GHCR PAT (image pull, only if package goes private)

1. Create new fine-grained PAT with `read:packages`.
2. `kubectl -n goshop create secret docker-registry ghcr-pull --dry-run=client … | kubectl apply -f -`
3. Restart deploy/goshop.

## Doppler service token

1. Create new service token in Doppler (read-only on `prod`).
2. Update the Secret in cluster:
   ```bash
   kubectl -n external-secrets create secret generic doppler-token \
     --from-literal=serviceToken="$NEW" --dry-run=client -o yaml | kubectl apply -f -
   ```
3. Revoke the old token in Doppler.
