# A flake-parts module, so a consumer declares runner images as typed options
# instead of calling mkRunnerImage by hand. Each entry becomes
# `packages.<name>`. The options live in ./image-options.nix, so
# `devenvModules.default` can present the same set.
#
# `mkImage` is applied at import time by lib.nix. It cannot be read out of
# `inputs` here: flake-parts hands this module the CONSUMING flake's inputs,
# which have no coldstart in them.
{ mkImage }:
{ lib, flake-parts-lib, ... }:
let
  shared = import ./image-options.nix { inherit lib mkImage; };
in
{
  options.perSystem = flake-parts-lib.mkPerSystemOption (
    { config, pkgs, ... }:
    {
      options.snowplow.images = lib.mkOption {
        type = lib.types.attrsOf shared.imageType;
        default = { };
        description = "Runner images to build, one package per attribute.";
      };

      config.packages = shared.buildImages pkgs config.snowplow.images;
    }
  );
}
