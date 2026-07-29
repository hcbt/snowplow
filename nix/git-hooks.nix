# git-hooks.nix's own flake module rather than calling `git-hooks.lib.run` by
# hand: it wires `checks.pre-commit` and the devShell fragment for us.
{ inputs, ... }:
{
  imports = [ inputs.git-hooks.flakeModule ];

  perSystem =
    { config, lib, ... }:
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

      # PRE_COMMIT_COLOR=never, or `checks.pre-commit` fails on Linux — every
      # hook, with the same unhelpful line:
      #
      #   An unexpected error has occurred: FileNotFoundError: [Errno 2] …
      #
      # To colourise hook output pre-commit runs the hook under a pty
      # (`cmd_output_p` → `openpty()`), and the Linux build sandbox has no
      # /dev/ptmx. Turning colour off takes the plain non-pty path instead.
      # macOS never hits this: its build sandbox is relaxed enough to have a
      # working /dev.
      checks.pre-commit = lib.mkForce (
        config.pre-commit.settings.run.overrideAttrs (_: {
          PRE_COMMIT_COLOR = "never";
        })
      );
    };
}
