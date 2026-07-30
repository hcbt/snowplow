{
  description = "Nix-built self-hosted GitHub Actions runners for Kubernetes — an OCI image builder and a Helm chart, no operator";

  inputs = {
    # The shared scaffolding: treefmt, the git hooks, mkDevShell, the app
    # helpers, and the generated GitHub-side files. Replaces the treefmt-nix
    # and git-hooks inputs this flake used to declare itself.
    nivis.url = "github:hcbt/nivis/v0.7.1";

    # flake-parts builds `pkgs` from the CONSUMING flake's own nixpkgs input,
    # so this cannot be dropped.
    nixpkgs.follows = "nivis/nixpkgs";

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

  outputs =
    inputs@{ nivis, ... }:
    nivis.inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = nivis.lib.defaultSystems;

      imports = [
        (nivis.flakeModules.default {
          srcRoot = ./.;
          repo = {
            initialVersion = "0.1.0";
          };
        })

        ./nix/lib.nix # flake.lib.mkRunnerImage / renderChart, flakeModules.default
        ./nix/packages.nix # the reference image + the packaged chart
        ./nix/checks.nix # chart lint + render assertions, image evaluation
        ./nix/shells.nix # `nix develop`
        ./nix/format.nix # the repo-specific half of treefmt and the hooks
      ];
    };
}
