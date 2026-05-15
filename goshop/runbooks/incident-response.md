# Incident response — goshop

## First 5 minutes

1. **Acknowledge** the Discord alert (react with 👀).
2. **Check Grafana** — `https://grafana.goshop.quangdang.dev`
   - Dashboard: "GoShop RED" (request rate, errors, duration)
   - Dashboard: "Kubernetes / Pods" — filter `namespace=goshop`
3. **Check ArgoCD** — was a deploy in progress?
   ```bash
   argocd app get goshop
   ```

## Common causes

### Pod crashloop
```bash
kubectl -n goshop describe pod -l app.kubernetes.io/name=goshop | grep -A20 Events
kubectl -n goshop logs -l app.kubernetes.io/name=goshop --tail=200 --previous
```
- ImagePullBackOff → check GHCR status / pull secret
- CrashLoopBackOff with config error → recent ConfigMap change? `git log -p charts/goshop/values*.yaml`
- OOMKilled → bump `resources.limits.memory` in values

### 5xx surge
- Check `/metrics` for handler-level breakdown
- Check Postgres saturation (`pg_stat_activity`, connection count)
- Check Redis (`redis-cli info stats`)
- Trace an error in Tempo from a Loki log line (click trace_id)

### Database down
- See `restore-postgres.md`
- If just restarting: `kubectl -n data rollout restart statefulset/postgresql`

## Rollback

```bash
# rollback ArgoCD to previous synced revision
argocd app rollback goshop <revision>
# OR revert the values commit
git revert <sha> && git push
```

## Escalate

If unresolved after 30 min, post in Discord channel `#goshop-incidents` with:
- timeline of events
- last good deploy SHA
- Grafana screenshots
- relevant Loki query
