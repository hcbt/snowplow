# A consumer flake: build a runner image with your own toolchain in it.
#
# Copy the parts you need into your infrastructure flake. Both styles below
# produce the same derivation — pick one.
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    snowplow.url = "github:hcbt/snowplow";
    snowplow.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    inputs@{ flake-parts, snowplow, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];

      imports = [ snowplow.flakeModules.default ];

      perSystem =
        { pkgs, ... }:
        {
          # Typed options. Each entry becomes packages.<name>.
          #
          #   nix build .#ci-runner
          snowplow.images.ci-runner = {
            # Whatever your workflows shell out to that a from-scratch Nix
            # image does not already carry.
            extraPackages = with pkgs; [
              yq-go
              jq
              docker-client
            ];

            # Extra binary caches, declared in the image rather than by an
            # action: cachix/cachix-action runs `nix-env -iA cachix` at job
            # start, which does not work in a from-scratch Nix container.
            nixSettings.substituters = [
              "https://cache.nixos.org"
              "https://devenv.cachix.org"
            ];
            nixSettings.trusted-public-keys = [
              "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
              "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
            ];

            # Links the pushed package to your repository, so it inherits the
            # repository's permissions instead of needing access granted by hand.
            labels."org.opencontainers.image.source" = "https://github.com/OWNER/REPO";
          };

          # The same thing without the module, if you would rather not import it.
          #
          #   nix build .#other-runner
          packages.other-runner = snowplow.lib.mkRunnerImage {
            inherit pkgs;
            name = "other-runner";
            extraPackages = [ pkgs.awscli2 ];
          };

          # Render the chart to plain manifests, for clusters driven by
          # `kubectl apply` rather than a GitOps controller.
          #
          #   nix build .#runner-manifests && cat result
          packages.runner-manifests = snowplow.lib.renderChart {
            inherit pkgs;
            namespace = "ci-runners";
            values = {
              image.repository = "ghcr.io/OWNER/ci-runner";
              imagePullSecrets = [ "ghcr-credentials" ];
              auth.secretName = "runner-pat";
              runners = [
                {
                  name = "my-repo";
                  url = "https://github.com/OWNER/REPO";
                  labels = "nix-x64";
                }
              ];
            };
          };
        };
    };
}
