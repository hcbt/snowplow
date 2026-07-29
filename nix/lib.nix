# The public surface: everything a consumer flake imports.
#
#   inputs.snowplow.lib.mkRunnerImage   build the image from any nixpkgs
#   inputs.snowplow.lib.renderChart     render the chart to plain manifests
#   inputs.snowplow.lib.chart           the chart source, for ArgoCD/helm
#   inputs.snowplow.flakeModules.default  typed options instead of the raw call
{ lib, flake-parts-lib, ... }:
let
  mkRunnerImage = args: import ./image.nix args;
  chart = ../chart;

  # Renders the chart to a single manifest file with no cluster and no network,
  # for consumers that would rather commit/apply plain YAML than point a GitOps
  # controller at this repository.
  renderChart =
    {
      pkgs,
      releaseName ? "snowplow",
      namespace ? "snowplow",
      values ? { },
      valuesFiles ? [ ],
      extraArgs ? [ ],
    }:
    let
      valuesFile = pkgs.writeText "snowplow-values.json" (builtins.toJSON values);
      allValues = valuesFiles ++ [ valuesFile ];
    in
    pkgs.runCommand "snowplow-manifests.yaml"
      {
        nativeBuildInputs = [ pkgs.kubernetes-helm ];
      }
      ''
        # helm insists on writable HOME-derived directories even for an offline
        # `template`, and $HOME is not set in the build sandbox.
        export HELM_CACHE_HOME="$TMPDIR/cache" HELM_CONFIG_HOME="$TMPDIR/config" HELM_DATA_HOME="$TMPDIR/data"
        helm template ${lib.escapeShellArg releaseName} ${chart} \
          --namespace ${lib.escapeShellArg namespace} \
          ${lib.concatMapStringsSep " " (f: "--values ${f}") allValues} \
          ${lib.escapeShellArgs extraArgs} > $out
      '';

  userType = lib.types.submodule {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        default = "runner";
        description = "Unprivileged account name declared in /etc/passwd.";
      };
      uid = lib.mkOption {
        type = lib.types.int;
        default = 1000;
        description = "uid the jobs run as. Must match the chart's podSecurityContext.runAsUser.";
      };
      gid = lib.mkOption {
        type = lib.types.int;
        default = 1000;
        description = "gid the jobs run as. Must match the chart's podSecurityContext.runAsGroup.";
      };
      home = lib.mkOption {
        type = lib.types.str;
        default = "/runner";
        description = "Home directory, and the default RUNNER_ROOT.";
      };
      shell = lib.mkOption {
        type = lib.types.str;
        default = "/bin/bash";
        description = "Login shell recorded in /etc/passwd.";
      };
    };
  };

  imageType = lib.types.submodule (
    { name, ... }:
    {
      options = {
        name = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "Image name. Defaults to the attribute name.";
        };
        tag = lib.mkOption {
          type = lib.types.str;
          default = "latest";
          description = "Image tag.";
        };
        runnerPackage = lib.mkOption {
          type = lib.types.nullOr lib.types.package;
          default = null;
          defaultText = lib.literalExpression "pkgs.github-runner";
          description = "The Runner.Listener package, overridable to pin a version.";
        };
        extraPackages = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [ ];
          description = "Toolchain the CI jobs need on top of the base set.";
        };
        nixSettings = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
          example = lib.literalExpression ''
            {
              substituters = [ "https://cache.nixos.org" "https://devenv.cachix.org" ];
            }
          '';
          description = "Merged over the default /etc/nix/nix.conf settings.";
        };
        env = lib.mkOption {
          type = lib.types.attrsOf (lib.types.nullOr lib.types.str);
          default = { };
          description = "Merged over the default environment; null removes a default.";
        };
        labels = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = { };
          example = lib.literalExpression ''
            { "org.opencontainers.image.source" = "https://github.com/OWNER/REPO"; }
          '';
          description = "OCI image labels.";
        };
        user = lib.mkOption {
          type = userType;
          default = { };
          description = "The unprivileged account the image declares.";
        };
        includeNixDB = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Seed /nix/var/nix/db so nix commands work inside the container.";
        };
        withSkopeo = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Include skopeo and a permissive containers trust policy.";
        };
      };
    }
  );
in
{
  flake = {
    lib = {
      inherit mkRunnerImage renderChart chart;
    };

    # A flake-parts module, so a consumer declares images as typed options
    # instead of calling mkRunnerImage by hand:
    #
    #   imports = [ inputs.snowplow.flakeModules.default ];
    #   perSystem = { pkgs, ... }: {
    #     snowplow.images.ci-runner.extraPackages = [ pkgs.yq-go ];
    #   };
    #
    # Each entry becomes `packages.<name>`.
    flakeModules.default = {
      options.perSystem = flake-parts-lib.mkPerSystemOption (
        { config, pkgs, ... }:
        {
          options.snowplow.images = lib.mkOption {
            type = lib.types.attrsOf imageType;
            default = { };
            description = "Runner images to build, one package per attribute.";
          };

          config.packages = lib.mapAttrs (
            _: image:
            mkRunnerImage (
              {
                inherit pkgs;
                inherit (image)
                  name
                  tag
                  extraPackages
                  nixSettings
                  env
                  labels
                  user
                  includeNixDB
                  withSkopeo
                  ;
              }
              // lib.optionalAttrs (image.runnerPackage != null) { inherit (image) runnerPackage; }
            )
          ) config.snowplow.images;
        }
      );
    };
  };
}
