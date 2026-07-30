# The one thing the RUNNER image has to supply itself, because nothing upstream
# does.
#
# It is an absence rather than a misconfiguration, so it does not show up when
# the image is built, or inspected, or started — only when a job happens to
# need it, at the cost of a full CI round-trip.
#
# The generic shims that used to live here — /usr/bin/env and the skopeo trust
# policy — moved to coldstart, which every image built here now goes through.
#
# Kept out of image.nix so `checks.nix` can exercise this directly: proving it
# works means RUNNING it, and building the whole image to do that would pull
# ~2G of closure into `nix flake check`.
{ pkgs }:
let
  inherit (pkgs) lib;
in
{
  # The runner evaluates the expression functions it implements itself — most
  # visibly `hashFiles()` — by spawning a bundled "internal" node. That version
  # is hard-coded to node20: `NodeUtil._defaultNodeVersion`, with node20 the
  # only member of `BuiltInNodeVersions`, so no environment variable can move it
  # to the node24 the same runner uses for actions. And unlike every other
  # directory nixpkgs relocates, it is resolved from the Runner.Worker binary's
  # own location, so it has to exist inside the runner's store path:
  #
  #   The template is not valid. System.ComponentModel.Win32Exception (2):
  #   An error occurred trying to start process
  #   '/nix/store/…-github-runner-2.335.1/lib/externals/node20/bin/node'
  #
  # nixpkgs links only `externals/node24` — nodejs_20 is EOL and gone from
  # nixpkgs, and github-runner's `nodeRuntimes` assertion accepts nothing else —
  # so `hashFiles()` is broken on every nixpkgs-built runner. It fails while the
  # step's expressions are being EVALUATED, which is worse than a failing step:
  # the step never starts, every later step is skipped, and a step meant to
  # report the job's verdict is skipped with them. A job can end up looking
  # green.
  #
  # A copy rather than `overrideAttrs`: the package is ~11M of already-built
  # assemblies, while overriding `postInstall` rebuilds the whole dotnet package
  # and its test suite from source — here, and in every consumer, on every
  # image build.
  withInternalNode =
    pkg:
    pkgs.runCommand "${pkg.name}-internal-node" { } ''
      cp -a ${pkg} $out
      chmod -R u+w $out

      externals="$out/lib/externals"
      if [ ! -e "$externals/node20" ]; then
        # Whatever the package does ship stands in for the missing node20. The
        # scripts run through it are plain bundled JavaScript, and a newer node
        # runs them unchanged; the directory name is the runner's, not ours.
        # Relative, so it keeps pointing inside this copy.
        newest=$(ls "$externals" | sort -V | tail -1)
        if [ -z "$newest" ]; then
          echo "${pkg} ships no externals at all — nothing to stand in for node20" >&2
          exit 1
        fi
        ln -s "$newest" "$externals/node20"
      fi
      test -x "$externals/node20/bin/node"

      # makeWrapper baked the original store path into every wrapper, and a
      # wrapper that execs the original defeats the copy entirely: the worker
      # would resolve its externals over there and find no node20 again. Text
      # files only — rewriting a compiled binary would change its length.
      for f in $(grep -rIl ${pkg} $out || true); do
        substituteInPlace "$f" --replace-quiet ${pkg} "$out"
      done
    '';
}
