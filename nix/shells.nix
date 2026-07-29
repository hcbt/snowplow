# `nix develop` / direnv.
#
# A plain mkShell, not devenv: devenv's flake module refuses to evaluate without
# `devenv.root`, which under a pure flake can only point at the store copy of
# this source — devenv then fails trying to create its state directory inside
# /nix/store. The documented way around it (a `devenv-root` input overridden
# per-invocation) makes every `nix develop` need `--impure`, which is a poor
# trade for a repo with no processes, services or language integrations to
# manage. Add devenv the day this shell needs one of those.
{ ... }:
{
  perSystem =
    { pkgs, config, ... }:
    {
      devShells.default = pkgs.mkShell {
        # git-hooks' flake module builds the fragment that materialises the
        # generated `.pre-commit-config.yaml` and installs the hook.
        inputsFrom = [ config.pre-commit.devShell ];

        packages = [
          # working on the chart
          pkgs.kubernetes-helm
          pkgs.kubectl
          pkgs.kubeconform
          pkgs.yq-go
          # `nix fmt` in the shell, same binary the hooks and the check use
          config.treefmt.build.wrapper
          # Shell tooling — `nix develop` is IMPURE: it prepends these to the
          # ambient PATH rather than replacing it, so anything NOT listed here
          # silently falls through to a host binary.
          pkgs.git
          pkgs.gh
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.gnused
          pkgs.findutils
          pkgs.curl
        ];
      };
    };
}
