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
  options.snowplow.pkgs = lib.mkOption {
    type = lib.types.raw;
    default = pkgs;
    defaultText = "pkgs";
    description = ''
      The package set the images are BUILT from.

      Defaults to the environment's `pkgs`, which for a devenv project is
      devenv's own channel. An image that has to stay on a different nixpkgs —
      the one its consumers were pinned against — sets this instead. Getting it
      wrong rebuilds the image from another package set without saying so.
    '';
  };

  options.snowplow.images = lib.mkOption {
    type = lib.types.attrsOf shared.imageType;
    default = { };
    description = "Runner images to build, one output per attribute.";
  };

  config.outputs = shared.buildImages config.snowplow.pkgs config.snowplow.images;
}
