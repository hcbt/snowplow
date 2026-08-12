# A devenv module, so a devenv project declares runner images as typed options
# instead of calling mkRunnerImage by hand. Each entry becomes
# `outputs.<name>`, built with `devenv build outputs.<name>`.
#
# It exists because devenv `outputs` is typed `outputOf lib.types.attrs`, and a
# Nix function fails that check — `lib.mkRunnerImage` cannot be published to a
# devenv project the way it is published to a flake. Options can.
#
# `coldstart` is a `flake: false` input in the consumer's devenv.yaml, so
# `mkImage` is imported by PATH: that input is the source tree, not flake
# outputs.
{
  lib,
  config,
  pkgs,
  inputs,
  ...
}:
let
  mkImage = args: import "${inputs.coldstart}/nix/image.nix" args;
  shared = import ./image-options.nix { inherit lib mkImage; };
in
{
  options.snowplow.images = lib.mkOption {
    type = lib.types.attrsOf shared.imageType;
    default = { };
    description = "Runner images to build, one output per attribute.";
  };

  config.outputs = shared.buildImages pkgs config.snowplow.images;
}
