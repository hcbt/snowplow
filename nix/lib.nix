# The public surface: everything a consumer flake imports.
#
#   inputs.snowplow.lib.mkRunnerImage   build the image from any nixpkgs
#   inputs.snowplow.lib.renderChart     render the chart to plain manifests
#   inputs.snowplow.lib.chart           the chart source, for ArgoCD/helm
#   inputs.snowplow.flakeModules.default  typed options instead of the raw call
{ lib, inputs, ... }:
let
  # coldstart's image builder is applied HERE, once, rather than reached for
  # inside `image.nix` or `flake-module.nix`. flake-parts threads the CONSUMING
  # flake's `inputs` into every module it evaluates, so a module that read
  # `inputs.coldstart` would force every consumer to declare coldstart itself —
  # which is most of the boilerplate this repo exists to remove.
  inherit (inputs.coldstart.lib) mkImage;

  mkRunnerImage = args: import ./image.nix { inherit mkImage; } args;
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
in
{
  flake = {
    lib = {
      inherit mkRunnerImage renderChart chart;
    };

    flakeModules.default = import ./flake-module.nix { inherit mkImage; };
  };
}
