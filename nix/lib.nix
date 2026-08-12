# The public surface: everything a consumer flake imports.
#
#   inputs.snowplow.lib.mkRunnerImage   build the image from any nixpkgs
#   inputs.snowplow.lib.renderChart     render the chart to plain manifests
#   inputs.snowplow.lib.chart           the chart source, for ArgoCD/helm
#   inputs.snowplow.flakeModules.default  typed options instead of the raw call
{ lib, inputs }:
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
  lib = {
    inherit mkRunnerImage renderChart chart;
  };

  # Still exported, even though this flake no longer runs flake-parts itself.
  # stakles imports it to declare `snowplow.images.github-runner-image`.
  # The same options, for a project that runs devenv rather than a flake. A
  # PATH, not an imported module: devenv resolves its own imports, and a
  # consumer names it as `snowplow/nix/devenv-module.nix` under a
  # `flake: false` input.
  #
  # It exists because devenv `outputs` is typed `outputOf lib.types.attrs`, so
  # a Nix function fails the check — `lib.mkRunnerImage` cannot reach a devenv
  # project as a function, but the options can.
  devenvModules.default = ./devenv-module.nix;
}
