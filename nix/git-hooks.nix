# git-hooks.nix's own flake module rather than calling `git-hooks.lib.run` by
# hand: it wires `checks.pre-commit` and the installation script the devenv
# shell runs on entry.
{ inputs, ... }:
{
  imports = [ inputs.git-hooks.flakeModule ];

  perSystem =
    { config, ... }:
    {
      pre-commit = {
        check.enable = true;

        settings.hooks = {
          # Formatting is treefmt's job — one hook keeps the hook set from
          # drifting away from `nix fmt` and `checks.treefmt`.
          treefmt = {
            enable = true;
            packageOverrides.treefmt = config.treefmt.build.wrapper;
          };

          check-merge-conflicts.enable = true;
          check-added-large-files.enable = true;
          check-yaml = {
            enable = true;
            # Helm templates are not YAML until rendered.
            excludes = [ "^chart/templates/" ];
          };
        };
      };
    };
}
