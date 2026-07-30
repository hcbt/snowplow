# CLAUDE.md

snowplow builds self-hosted GitHub Actions runners for Kubernetes: an OCI image
builder and a Helm chart, no operator. The consumer-facing surface is
`lib.mkRunnerImage`, `lib.renderChart`, `lib.chart` and
`flakeModules.default` — changing any of them changes someone else's cluster.

## Layout

- `nix/lib.nix` — the public surface, exported as `flake.lib` / `flake.flakeModules`.
- `nix/image.nix` — the runner image.
- `nix/packages.nix` — the reference image and the packaged chart.
- `nix/checks.nix` — chart lint, render assertions, and consumer-flake evaluation.
- `nix/format.nix` — the repo-specific half of treefmt and the hooks.
- `nix/shells.nix` — `nix develop`.
- `chart/` — the Helm chart.

## Shared scaffolding

The dev shell, treefmt, the git hooks and the GitHub-side files come from
[nivis](https://github.com/hcbt/nivis), pinned in `flake.nix`.

- **Do not add a treefmt or git-hooks module here.** nivis brings nixfmt,
  prettier and the language-agnostic hook set; `nix/format.nix` adds only what
  is specific to this repo (the Helm template exclusions).
- **`.envrc`, `.github/dependabot.yml`, and the `Update flake.lock` and
  release-please workflows are generated.** Edit them in nivis, then run
  `nix run .#sync-repo` here. `checks.repo-files-current` fails on drift.
- `.release-please-manifest.json` is seeded once and then owned by
  release-please. It is not compared.
- Bumping nivis: `nix flake update nivis`, then `nix develop` **before**
  committing — the generated `.pre-commit-config.yaml` is only rewritten on
  shell entry, and a stale one runs the previous formatter.
- If a commit fails with `pre-commit's script is installed in migration mode`,
  delete `.git/hooks/*.legacy`. Those are left over from python `pre-commit`,
  which this repo used before nivis brought `prek`; prek preserves and then
  calls them, and the stale python script errors. Local state only — nothing
  in the repo needs changing.

`.github/workflows/ci.yml` is this repo's own and is not generated: it builds
the image and smoke-tests `build-push-image.yml`, which nothing else exercises.

## Invariants

- **`flake.lib` and `flake.flakeModules` are unchecked outputs.** `nix flake
check` reports "The following flake outputs are unchecked", so the
  consumer-facing half is only covered by `checks.example-flake` and
  `checks.flake-module`. A change to `nix/lib.nix` with no change there is
  untested.
- **Assertions run against rendered YAML with `yq`, never `grep`.** The
  templates carry long comments that survive into the output, so a grep for
  `--ephemeral` matches a comment about ephemeral runners whether or not the
  flag is there. The two assertions that must read the container command as
  text strip comment lines first (`command()` in `chart-render-defaults`).
- **The container command supervises the listener in a loop, and must never go
  back to `exec Runner.Listener run`.** An ephemeral listener exits 0 after one
  job; `restartPolicy: Always` counts that as a crash, and the kubelet's
  exponential backoff then _becomes_ the job queue — CrashLoopBackOff, and jobs
  waiting up to five minutes for a runner to exist. The loop reads like
  needless machinery precisely because what it prevents is invisible.
  `checks.chart-runner-supervision` executes the rendered script against a fake
  `Runner.Listener` to catch a regression; no assertion on the manifest can.
- **Helm templates are not YAML.** Both prettier and the `check-yaml` hook
  exclude `chart/templates/` — Go template directives do not parse.
- Releases come from release-please. Do not tag by hand.
