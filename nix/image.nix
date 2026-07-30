# The runner OCI image.
#
# Everything generic about "a Nix-built workload in a container" now lives in
# coldstart — /usr/bin/env, the /etc/passwd entry, the registered Nix database,
# the container-shaped nix.conf, the TLS roots, the skopeo trust policy. What
# is left here is what is actually about GitHub Actions.
#
# Takes `mkImage` as an import-time parameter rather than reaching for
# `inputs.coldstart`: flake-parts threads the CONSUMING flake's inputs into
# every module it evaluates, so a module that reached for coldstart would force
# every consumer to declare it too. `nix/lib.nix` applies it once.
#
#   snowplow.lib.mkRunnerImage { inherit pkgs; name = "my-runner"; }
{ mkImage }:
{
  pkgs,

  # Image name and tag. The tag is normally left at `latest` and the real
  # versioning is done by whatever publishes the image (a commit-SHA tag, an
  # ArgoCD image updater tracking the digest of `latest`, …).
  name ? "snowplow-runner",
  tag ? "latest",

  # The runner itself. Overridable so a consumer can pin an exact
  # Runner.Listener version rather than following nixpkgs.
  runnerPackage ? pkgs.github-runner,

  # Toolchain the CI jobs need on top of the base set below. This is the main
  # customisation point: whatever `runs-on` jobs shell out to goes here.
  extraPackages ? [ ],

  # Merged over coldstart's defaults, so a consumer can add substituters/keys
  # or flip a setting without restating the base.
  nixSettings ? { },

  # Merged over the default environment; `null` removes a default entirely.
  env ? { },

  # OCI labels. Setting org.opencontainers.image.source to the repository URL is
  # what links a GHCR package to its repo, so the package inherits the repo's
  # permissions instead of needing access granted by hand.
  labels ? { },

  # The unprivileged user the image declares. Postgres' initdb (and anything
  # else that refuses to run as root) is the reason jobs do not run as uid 0.
  user ? { },

  # Seeds /nix/var/nix/db so `nix build` works inside the container.
  includeNixDB ? true,

  # skopeo lets a job push images to a registry with no Docker daemon, which is
  # the usual reason to want a Nix runner in the first place. On by default
  # here, unlike in coldstart, because that is what CI is for.
  withSkopeo ? true,
}:
let
  # The one shim that is still snowplow's: the runner's bundled "internal"
  # node, which nixpkgs does not ship. image-shims.nix explains it at length,
  # and checks.nix executes it.
  shims = import ./image-shims.nix { inherit pkgs; };

  runner = shims.withInternalNode runnerPackage;

  defaultUser = {
    name = "runner";
    uid = 1000;
    gid = 1000;
    home = "/runner";
    shell = "/bin/bash";
  };
  u = defaultUser // user;
in
mkImage {
  inherit
    pkgs
    name
    tag
    includeNixDB
    withSkopeo
    nixSettings
    labels
    ;

  user = u;

  # Provides bin/Runner.Listener, which performs both the
  # PAT -> registration-token exchange and the job loop; no wrapper needed.
  packages = [ runner ];

  # On top of coldstart's base set. actions/checkout and most other JavaScript
  # actions need node; git is what every checkout shells out to; nix is the
  # entire reason for a Nix runner and coldstart includes it by default.
  extraPackages = [
    pkgs.git
    pkgs.nodejs
  ]
  ++ extraPackages;

  env = {
    # Runner state (.runner, .credentials) and HOME share one directory so the
    # worker finds credentials without the symlink dance the NixOS module does.
    # coldstart already points HOME at the user's home; this makes the runner
    # agree.
    RUNNER_ROOT = u.home;
  }
  // env;
}
