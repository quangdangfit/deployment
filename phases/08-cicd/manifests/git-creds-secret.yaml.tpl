# Template, substitute với envsubst trước khi apply.
# ArgoCD repo-creds Secret cho HTTPS auth (username + token).
apiVersion: v1
kind: Secret
metadata:
  name: git-creds
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repo-creds
stringData:
  type: git
  url: https://github.com/quangdangfit/deployment
  username: ${GIT_USER}
  password: ${GIT_TOKEN}
