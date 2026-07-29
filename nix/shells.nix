# `nix develop` / direnv.
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
