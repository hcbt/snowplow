# The runner OCI image.
#
# A plain function of `pkgs` and nothing else — no flake, no flake-parts, no
# `self`. That is deliberate: a consumer flake can call it with its own nixpkgs
# and get an image built against the exact package set the rest of its CI uses,
# without inheriting this repo's nixpkgs pin.
#
#   snowplow.lib.mkRunnerImage { inherit pkgs; name = "my-runner"; }
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

  # Merged over the defaults, so a consumer can add substituters/keys or flip a
  # setting without restating the base. List values are joined with spaces,
  # bools rendered as true/false.
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

  # Seeds /nix/var/nix/db so `nix build` works inside the container; without it
  # the store paths are present but unregistered and every nix command fails.
  # Costs reproducibility (db.sqlite embeds timestamps) — usually worth it.
  includeNixDB ? true,

  # skopeo lets a job push images to a registry with no Docker daemon, which is
  # the usual reason to want a Nix runner in the first place. Pulls in the trust
  # policy below with it.
  withSkopeo ? true,
}:
let
  inherit (pkgs) lib;

  defaultUser = {
    name = "runner";
    uid = 1000;
    gid = 1000;
    home = "/runner";
    shell = "/bin/bash";
  };
  u = defaultUser // user;

  defaultNixSettings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    # The container is the isolation boundary, so the build sandbox is
    # redundant — and there is only root inside it, so there are no build users
    # to hand a sandboxed build to.
    sandbox = false;
    build-users-group = "";
    substituters = [ "https://cache.nixos.org" ];
    trusted-public-keys = [ "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=" ];
  };

  renderSetting =
    v:
    if lib.isList v then
      lib.concatMapStringsSep " " toString v
    else if lib.isBool v then
      lib.boolToString v
    else
      toString v;

  # Substituters are declared in the image rather than by an action in the
  # workflow: cachix/cachix-action runs `nix-env -iA cachix` at job start, which
  # does not work in a from-scratch Nix container ("Error: not found: cachix").
  nixConf = pkgs.writeTextDir "etc/nix/nix.conf" (
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList (k: v: "${k} = ${renderSetting v}") (defaultNixSettings // nixSettings)
    )
    + "\n"
  );

  # skopeo refuses to do anything without a trust policy, and nixpkgs ships no
  # default one ("no policy.json file found"). Accept any image: a CI container
  # only ever pushes images it just built itself.
  containersPolicy = pkgs.writeTextDir "etc/containers/policy.json" (
    builtins.toJSON {
      default = [ { type = "insecureAcceptAnything"; } ];
    }
  );

  defaultEnv = {
    PATH = "/bin";
    # Runner state (.runner, .credentials) and HOME share one directory so the
    # worker finds credentials without the symlink dance the NixOS module does.
    RUNNER_ROOT = u.home;
    HOME = u.home;
    USER = u.name;
    TMPDIR = "/tmp";
    # skopeo stores credentials under $XDG_RUNTIME_DIR (or /run/containers/$UID
    # when unset), and an unprivileged uid cannot create /run — `skopeo login`
    # dies with "mkdir /run: permission denied". Point both at the writable
    # runner home. XDG_RUNTIME_DIR is set too so other tools that expect it do
    # not hit the same wall.
    REGISTRY_AUTH_FILE = "${u.home}/.config/containers/auth.json";
    XDG_RUNTIME_DIR = "${u.home}/.run";
    SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    NIX_SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  };

  finalEnv = lib.filterAttrs (_: v: v != null) (defaultEnv // env);
in
pkgs.dockerTools.buildLayeredImage {
  inherit name tag includeNixDB;

  contents = [
    # Provides bin/Runner.Listener, which performs both the
    # PAT -> registration-token exchange and the job loop; no wrapper needed.
    runnerPackage

    # Toolchain the runner shells out to. actions/checkout and most other
    # JavaScript actions need node; everything else here is what a shell step
    # assumes exists.
    pkgs.bashInteractive
    pkgs.coreutils-full
    pkgs.findutils
    pkgs.gnugrep
    pkgs.gnused
    pkgs.gnutar
    pkgs.gzip
    pkgs.git
    pkgs.nodejs

    pkgs.nix

    # TLS for api.github.com, the registry and the binary cache.
    pkgs.cacert

    # /etc/passwd and /etc/group. Stock fakeNss only defines root and nobody —
    # with no entry for the uid the pod runs as, nix cannot resolve the user
    # and every job dies with "error: cannot determine user's home directory".
    (pkgs.dockerTools.fakeNss.override {
      extraPasswdLines = [
        "${u.name}:x:${toString u.uid}:${toString u.gid}:${u.name}:${u.home}:${u.shell}"
      ];
      extraGroupLines = [ "${u.name}:x:${toString u.gid}:" ];
    })

    nixConf
  ]
  ++ lib.optionals withSkopeo [
    pkgs.skopeo
    containersPolicy
  ]
  ++ extraPackages;

  config = {
    Env = lib.mapAttrsToList (k: v: "${k}=${toString v}") finalEnv;
    WorkingDir = u.home;
    Labels = labels;
  };
}
