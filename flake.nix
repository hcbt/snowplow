{
  description = "Nix-built self-hosted GitHub Actions runners for Kubernetes — an OCI image builder and a Helm chart, no operator";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

    # One formatter for every language in the repo, exposed as `nix fmt`, a
    # `treefmt` check, and the formatting half of the git hooks.
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";

    git-hooks.url = "github:cachix/git-hooks.nix";
    git-hooks.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      imports = [
        ./nix/lib.nix # flake.lib.mkRunnerImage / renderChart, flakeModules.default
        ./nix/packages.nix # the reference image + the packaged chart
        ./nix/checks.nix # chart lint + render assertions, image evaluation
        ./nix/shells.nix # `nix develop`
        ./nix/treefmt.nix # `nix fmt` + checks.treefmt
        ./nix/git-hooks.nix # pre-commit, delegating formatting to treefmt
      ];
    };
}
