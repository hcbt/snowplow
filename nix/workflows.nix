# The workflows this repo owns, as text for `repo.extraFiles`.
#
# nivis generates `.envrc`, dependabot, release-please and the flake.lock
# workflow; these two are this repo's own. Routing them through `extraFiles`
# gives every workflow one writer and one drift check instead of half of them,
# so nothing in `.github/` can be edited and quietly diverge from its source.
#
# Verbatim YAML under `nix/ci/` rather than Nix strings: these files contain
# `'${{ … }}'`, and a quote immediately before an interpolation cannot be
# written unambiguously in a Nix indented string. `nix/ci/` is excluded from
# treefmt, or prettier reformats the source while the generated copy stays
# excluded and the two can never match.
{ }:
{
  ".github/workflows/build-push-image.yml" = builtins.readFile ./ci/build-push-image.yml;
  ".github/workflows/ci.yml" = builtins.readFile ./ci/ci.yml;
}
