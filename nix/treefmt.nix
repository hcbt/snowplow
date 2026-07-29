# One formatter for every language in the repo: `nix fmt`, a `checks.treefmt`
# that fails on unformatted files, and a single binary the git hooks reuse — so
# formatting is defined once rather than repeated per tool.
{ inputs, ... }:
{
  imports = [ inputs.treefmt-nix.flakeModule ];

  perSystem = {
    treefmt = {
      # Without this treefmt walks up looking for a VCS root and can format
      # outside the flake when evaluated from a subdirectory.
      projectRootFile = "flake.nix";

      programs = {
        nixfmt.enable = true;
        prettier.enable = true; # yaml/json/md — the chart values and the docs
      };

      settings.global.excludes = [
        "*.lock"
        "flake.lock"
        "*.png"
        "*.svg"
        "*.ico"
        "LICENSE"
        # Helm templates are Go-templated YAML; prettier cannot parse `{{ … }}`.
        "chart/templates/*"
      ];
    };
  };
}
