# snowplow

Self-hosted GitHub Actions runners on Kubernetes, built with Nix. No operator, no
Dockerfile, no entrypoint script.

- **An image builder** — `lib.mkRunnerImage` produces an OCI image from nixpkgs:
  `Runner.Listener`, a Nix that works inside the container, and whatever
  toolchain your jobs need. There is no published image, because the useful part
  is the toolchain _you_ put in it.
- **A Helm chart** — one Deployment hosting every registration, one container
  each, all sharing a warm Nix store.

Made for the case where a hosted runner is not an option (no hosted minutes, a
private network, a build that wants a persistent Nix store) and a full runner
operator is more machinery than the job is worth.

## How it works

A registration is scoped to one repository or organisation, but that binds the
_registration_, not the machine. So one pod runs one `Runner.Listener` per entry
in `runners`, and they share everything underneath — most importantly `/nix`,
which is a cache, not state. Adding a repo is one entry in values, not another
Deployment and another volume.

Registration happens in each container's own startup rather than an
initContainer. With `--ephemeral` the listener exits after exactly one job and
the kubelet restarts the container — and initContainers do not re-run on a
container restart, only on a pod restart. Registering in the container is what
makes every job get a fresh runner instead of the pod dying after its first job.

That works because the stored credential is a **PAT**, from which a fresh
registration token is minted every time. A pre-generated registration token is
single-use and would not survive the second job.

## Quick start

### 1. Build an image

```nix
{
  inputs.snowplow.url = "github:hcbt/snowplow";

  # …inside flake-parts' perSystem:
  imports = [ inputs.snowplow.flakeModules.default ];

  snowplow.images.ci-runner = {
    extraPackages = with pkgs; [ yq-go jq ];
    nixSettings.substituters = [ "https://cache.nixos.org" "https://devenv.cachix.org" ];
    nixSettings.trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
    ];
    labels."org.opencontainers.image.source" = "https://github.com/OWNER/REPO";
  };
}
```

`nix build .#ci-runner` produces a `docker-archive`. Without the flake-parts
module, call `snowplow.lib.mkRunnerImage { inherit pkgs; … }` directly — see
[`examples/flake.nix`](examples/flake.nix).

Push it with the reusable workflow:

```yaml
jobs:
  runner-image:
    permissions:
      contents: read
      packages: write
    uses: hcbt/snowplow/.github/workflows/build-push-image.yml@master
    with:
      package: ci-runner
      image: ghcr.io/${{ github.repository_owner }}/ci-runner
    secrets:
      registry-password: ${{ secrets.GITHUB_TOKEN }}
```

### 2. Create the credential

A fine-grained PAT with **`Administration: read and write`** on every repository
the runners serve (or `self-hosted runners: read and write` on the organisation).
That permission is what lets a runner mint its own registration token at startup.

```bash
kubectl create secret generic runner-pat --from-literal=pat=<token> -n ci-runners
```

Any secrets operator works instead. For clusters running the 1Password
Kubernetes operator the chart can render the `OnePasswordItem` for you — see
`auth.onePassword` in [`chart/values.yaml`](chart/values.yaml).

### 3. Deploy the chart

```bash
helm upgrade --install runners \
  --namespace ci-runners --create-namespace \
  ./chart --values my-values.yaml
```

```yaml
# my-values.yaml
image:
  repository: ghcr.io/OWNER/ci-runner
imagePullSecrets: [ghcr-credentials]
auth:
  secretName: runner-pat
runners:
  - name: my-repo
    url: https://github.com/OWNER/REPO
    labels: nix-x64
```

Workflows then target it with `runs-on: nix-x64`.

Every value is documented inline in [`chart/values.yaml`](chart/values.yaml).

## Deploying with ArgoCD

The chart lives here and the values live in your infrastructure repo, so use a
multi-source Application:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: runners
  namespace: argocd
spec:
  project: default
  sources:
    - repoURL: https://github.com/hcbt/snowplow.git
      targetRevision: master
      path: chart
      helm:
        valueFiles:
          - $values/path/to/my-values.yaml
    - repoURL: https://github.com/OWNER/INFRA.git
      targetRevision: master
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: ci-runners
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
```

With `argocd-image-updater`, track the **digest** of a single mutable tag:

```yaml
spec:
  commonUpdateSettings:
    # `digest`, not `newest-build`. newest-build ranks tags by image creation
    # time, and dockerTools stamps every image at epoch 0 so it can be
    # reproducible — every tag looks equally old and nothing ever updates
    # (images_considered=1 images_updated=0, no error).
    updateStrategy: digest
    pullSecret: pullsecret:ci-runners/ghcr-credentials
    allowTags: "regexp:^latest$"
  applicationRefs:
    - namePattern: runners
      images:
        - alias: runner
          # The `:latest` suffix is the version constraint the digest strategy
          # requires — without it the controller errors with "cannot use update
          # strategy 'digest' … without a version constraint".
          imageName: ghcr.io/OWNER/ci-runner:latest
          manifestTargets:
            helm:
              name: image.repository
              tag: image.tag
```

Set `imageUpdater.rbac.enabled=true` so the controller may read the pull secret
in the runner namespace; without it, it logs `secrets "…" is forbidden` and
silently never updates.

Prefer plain manifests? `lib.renderChart` renders the chart with no cluster and
no network.

## Things that will bite you

Every one of these was paid for once already.

**`error: cannot determine user's home directory`** — Nix resolves the current
user through `getpwuid`, not `$HOME`. The pod runs unprivileged, and a
from-scratch image has no `/etc/passwd` entry for that uid. Images built here
carry one, and the chart also mounts one via ConfigMap (`nss.enabled`) — that
mount is what lets you recover when a bad image cannot build its own replacement.

**`chmod: changing permissions of '…': Operation not permitted` in every
unpackPhase** — a pod `fsGroup`. Kubelet marks the volume root setgid, every
directory created beneath it inherits it, `unpackPhase` runs `chmod -R u+w`
re-applying a mode carrying `S_ISGID`, and nix's `filter-syscalls` seccomp filter
denies exactly that. The chart sets no `fsGroup` and does the ownership work in
an initContainer instead. Do not add one.

**`Error: not found: cachix`** — `cachix/cachix-action` runs `nix-env -iA cachix`
at job start, which does not work in a from-scratch Nix container. Declare the
substituter in the image (`nixSettings`) and drop the action.

**`no policy.json file found`** — skopeo refuses to run without a trust policy
and nixpkgs ships no default. `withSkopeo = true` (the default) installs a
permissive one.

**`mkdir /run: permission denied` from `skopeo login`** — skopeo writes
credentials under `$XDG_RUNTIME_DIR`, or `/run/containers/$UID` when unset, and
an unprivileged uid cannot create `/run`. The image points `REGISTRY_AUTH_FILE`
and `XDG_RUNTIME_DIR` at the runner's home.

**A runner container crashlooping with a 403 from
`/actions/runners/registration-token`** — the PAT does not cover that entry's
repository. Every entry shares one credential unless it overrides `auth`.

**Building the runner image on the runner it produces** is circular but
recoverable: build and push from any machine with Nix.

```bash
nix build .#packages.x86_64-linux.ci-runner
nix shell nixpkgs#skopeo -c skopeo copy --all \
  "docker-archive:$(readlink -f result)" \
  docker://ghcr.io/OWNER/ci-runner:latest --dest-creds USER:TOKEN
```

## Development

```bash
nix develop        # helm, kubectl, kubeconform, yq, treefmt
nix flake check    # chart lint, render assertions, formatting, git hooks
nix build .#runner-image   # x86_64-linux / aarch64-linux only
nix fmt
```

The chart's tests render it with `helm template` and assert on the result with
`yq` — never `grep`, because the templates carry comments that survive into the
output and would match. See [`nix/checks.nix`](nix/checks.nix).

## License

MIT.
