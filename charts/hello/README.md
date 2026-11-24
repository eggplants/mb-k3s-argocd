# hello

A sample app: [traefik/whoami](https://github.com/traefik/whoami), which answers with the request it got. It shows that Argo CD and the Tailscale operator work, at `https://hello.<tailnet>` inside the tailnet.

## Install

Argo CD deploys it from `apps/templates/hello.yaml`, which the `apps` Application (`cluster/manifests/argocd-apps.yaml`) syncs. The Tailscale operator needs its OAuth client first (`mise run cluster:tailscale-oauth`); until then the Ingress has no address.

## Upgrade

Change `image.tag` (the tag and the digest of its multi-arch index) in `values.yaml`, and `appVersion` in `Chart.yaml`, then push. Dependabot opens these pull requests monthly.

## Uninstall

Delete `apps/templates/hello.yaml` and push: Argo CD prunes the Application. The Application has no resources-finalizer, so hello keeps running until its resources are deleted too:

```bash
kubectl delete namespace hello
```

Deleting the Ingress removes the `hello` device from the tailnet. Then delete `charts/hello/` and its line in `.github/dependabot.yml`.
