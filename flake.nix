{
  description = "Nix-built self-hosted GitHub Actions runners for Kubernetes — an OCI image builder and a Helm chart, no operator";

  inputs = {
    # Declared directly now that nivis is gone. nivis used to supply
    # flake-parts, the dev shell, the hooks, the formatter and a generator for
    # the GitHub-side files. devenv covers the shell and the hooks, and the
    # GitHub files are ordinary committed files again.
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # NOT `follows`-ed onto this flake's nixpkgs, deliberately. devenv is Rust,
    # and the binaries on devenv.cachix.org are built against
    # `cachix/devenv-nixpkgs/rolling`. Overriding its nixpkgs changes the
    # derivation hash, every substituter misses, and `devenv-tasks` and its
    # crate graph compile from source on each machine and each CI run.
    devenv.url = "github:cachix/devenv";

    # This one DOES follow: its hooks format this repository's files, so they
    # must run the same nixpkgs the rest of it is built from.
    git-hooks.url = "github:cachix/git-hooks.nix";
    git-hooks.inputs.nixpkgs.follows = "nixpkgs";

    # TEST-ONLY. This flake does not run flake-parts any more, but it still
    # PUBLISHES `flakeModules.default` — stakles imports it to declare
    # `snowplow.images.github-runner-image` — and `checks.flake-module`
    # evaluates that module the way stakles does. An exported module with no
    # test rots. Nothing imports flake-parts outside that check.
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

    # The generic container half, extracted from this repo: the OCI image
    # builder, /usr/bin/env, the /etc/passwd entry, the registered Nix
    # database, the container-shaped nix.conf and the skopeo trust policy.
    # What stays here is the GitHub Actions part — Runner.Listener, its
    # bundled node, and the chart that supervises it.
    coldstart = {
      url = "github:hcbt/coldstart";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  # devenv publishes its own builds, so the shell comes down prebuilt instead of
  # being compiled on every machine and every CI run.
  nixConfig = {
    extra-substituters = "https://devenv.cachix.org";
    extra-trusted-public-keys = "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=";
  };

  outputs =
    inputs@{
      nixpkgs,
      devenv,
      git-hooks,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];

      forEachSystem = nixpkgs.lib.genAttrs systems;
      inherit (nixpkgs) lib;

      # devenv's own package set. The shell is built from it, so the hooks check
      # must be too, or a developer's shell and CI run different binaries.
      devenvPkgsFor = forEachSystem (system: import devenv.inputs.nixpkgs { inherit system; });
    in
    # The public surface: `lib.mkRunnerImage`, `lib.renderChart`, `lib.chart`
    # and `flakeModules.default`. devenv exposes none of these, which is why
    # this flake stays.
    import ./nix/lib.nix { inherit lib inputs; }
    // {
      packages = forEachSystem (
        system:
        import ./nix/packages.nix { inherit inputs; } {
          pkgs = nixpkgs.legacyPackages.${system};
          inherit lib;
        }
      );

      checks = forEachSystem (
        system:
        import ./nix/checks.nix { inherit inputs; } {
          pkgs = nixpkgs.legacyPackages.${system};
          inherit lib;
        }
        // {
          # The hooks, as a check. `devenv.lib.mkShell` installs them for a
          # developer, but nothing in a devenv shell runs in CI — so without
          # this, an unformatted file reaches master and nothing says so.
          #
          # Built from devenv's package set, the same one the shell uses, so the
          # two cannot run different formatter versions.
          pre-commit = git-hooks.lib.${system}.run {
            src = ./.;
            package = devenvPkgsFor.${system}.prek;
            inherit ((import ./devenv.nix { pkgs = devenvPkgsFor.${system}; }).git-hooks)
              hooks
              excludes
              ;
          };
        }
      );

      # `nix develop` / direnv. The shell itself is in devenv.nix so it can be
      # diffed against the other repos' copies.
      devShells = forEachSystem (system: {
        default = devenv.lib.mkShell {
          inherit inputs;
          pkgs = devenvPkgsFor.${system};
          modules = [ ./devenv.nix ];
        };
      });
    };
}
