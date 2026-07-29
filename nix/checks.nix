# Tests. All offline: `helm template` needs no cluster, and every assertion runs
# against the rendered YAML with yq rather than grep — the templates carry long
# comments that survive into the output, so a grep for `--ephemeral` matches a
# comment about ephemeral runners whether or not the flag is there.
{ inputs, ... }:
{
  perSystem =
    { pkgs, lib, ... }:
    let
      chart = ../chart;
      exampleValues = ../examples/values-example.yaml;

      # `nix flake check` does not look at `flake.lib` or `flake.flakeModules`
      # ("The following flake outputs are unchecked"), so the consumer-facing
      # half of this repo is only covered by the two checks that use these.
      snowplow = (import ./lib.nix { inherit lib; }).flake;

      # Evaluates a flake-parts flake the way a consumer would, without needing
      # this flake's own outputs. `self` has to carry `inputs`: flake-parts
      # reads `self.inputs` to build the `inputs'` per-system arg.
      evalConsumerFlake =
        {
          inputs' ? { inherit (inputs) nixpkgs; },
          module,
        }:
        let
          allInputs = inputs' // {
            self = {
              inputs = allInputs;
              outPath = ../.;
            };
          };
        in
        inputs.nivis.inputs.flake-parts.lib.mkFlake { inputs = allInputs; } module;

      # Renders the chart, then runs the given assertions with $manifests bound
      # to the rendered file.
      mkRenderCheck =
        {
          name,
          helmArgs ? [ ],
          values ? [ exampleValues ],
          script,
        }:
        pkgs.runCommand name
          {
            nativeBuildInputs = [
              pkgs.kubernetes-helm
              pkgs.yq-go
            ];
          }
          ''
            export HELM_CACHE_HOME="$TMPDIR/cache" HELM_CONFIG_HOME="$TMPDIR/config" HELM_DATA_HOME="$TMPDIR/data"
            manifests="$TMPDIR/manifests.yaml"
            helm template test ${chart} --namespace ci \
              ${lib.concatMapStringsSep " " (v: "--values ${v}") values} \
              ${lib.escapeShellArgs helmArgs} > "$manifests"

            fail() { echo "FAIL: $*" >&2; exit 1; }
            # Every assertion below is `expected actual message`.
            eq() { [ "$1" = "$2" ] || fail "$3 (expected '$1', got '$2')"; }

            deployment() { yq 'select(.kind == "Deployment")' "$manifests"; }
            kinds() { yq -N '.kind' "$manifests" | sort -u; }

            ${script}

            touch $out
          '';
    in
    {
      checks = {
        # helm's own schema/template validation, and proof the example values
        # documented in the README actually render.
        chart-lint =
          pkgs.runCommand "chart-lint"
            {
              nativeBuildInputs = [ pkgs.kubernetes-helm ];
            }
            ''
              export HELM_CACHE_HOME="$TMPDIR/cache" HELM_CONFIG_HOME="$TMPDIR/config" HELM_DATA_HOME="$TMPDIR/data"
              helm lint ${chart} --values ${exampleValues}
              touch $out
            '';

        # The chart must refuse to render something that cannot work, rather
        # than emit a Deployment with zero containers or an empty image name.
        chart-rejects-incomplete-values =
          pkgs.runCommand "chart-rejects-incomplete-values"
            {
              nativeBuildInputs = [ pkgs.kubernetes-helm ];
            }
            ''
              export HELM_CACHE_HOME="$TMPDIR/cache" HELM_CONFIG_HOME="$TMPDIR/config" HELM_DATA_HOME="$TMPDIR/data"

              if helm template test ${chart} --namespace ci > /dev/null 2>&1; then
                echo "FAIL: chart rendered with no runners and no image" >&2
                exit 1
              fi

              if helm template test ${chart} --namespace ci --values ${exampleValues} \
                   --set image.repository= > /dev/null 2>&1; then
                echo "FAIL: chart rendered with an empty image.repository" >&2
                exit 1
              fi

              if helm template test ${chart} --namespace ci --values ${exampleValues} \
                   --set auth.onePassword.enabled=true > /dev/null 2>&1; then
                echo "FAIL: chart rendered 1Password integration with no itemPath" >&2
                exit 1
              fi

              touch $out
            '';

        chart-render-defaults = mkRenderCheck {
          name = "chart-render-defaults";
          script = ''
                        eq 2 "$(deployment | yq '.spec.template.spec.containers | length')" \
                          "one container per runners entry"
                        eq "runner-my-repo runner-my-org" \
                          "$(deployment | yq -N '.spec.template.spec.containers[].name' | tr '\n' ' ' | sed 's/ $//')" \
                          "containers named after the runners, in order"

                        # Registration flags, read out of the container command itself.
                        repoArgs="$(deployment | yq '.spec.template.spec.containers[0].args[1]')"
                        case "$repoArgs" in
                          *"--ephemeral"*) ;;
                          *) fail "ephemeral runner is missing --ephemeral" ;;
                        esac
                        case "$repoArgs" in
                          *'--url "https://github.com/OWNER/REPO"'*) ;;
                          *) fail "runner url not passed to configure" ;;
                        esac
                        case "$repoArgs" in
                          *'--labels "nix-x64"'*) ;;
                          *) fail "string labels not passed to configure" ;;
                        esac

                        orgArgs="$(deployment | yq '.spec.template.spec.containers[1].args[1]')"
                        case "$orgArgs" in
                          *"--ephemeral"*) fail "per-runner ephemeral:false was ignored" ;;
                        esac
                        case "$orgArgs" in
                          *'--labels "nix-x64,big"'*) ;;
                          *) fail "list labels not joined into a single --labels value" ;;
                        esac
                        case "$orgArgs" in
                          *'--runnergroup "nix"'*) ;;
                          *) fail "runner group not passed to configure" ;;
                        esac

                        # The credential is read from the Secret named in values, never
                        # baked into the manifest.
                        eq "runner-pat" \
                          "$(deployment | yq '.spec.template.spec.containers[0].env[] | select(.name == "GITHUB_PAT") | .valueFrom.secretKeyRef.name')" \
                          "PAT secret name comes from auth.secretName"
                        eq "pat" \
                          "$(deployment | yq '.spec.template.spec.containers[0].env[] | select(.name == "GITHUB_PAT") | .valueFrom.secretKeyRef.key')" \
                          "PAT secret key comes from auth.secretKey"

                        eq "/runners/my-repo" \
                          "$(deployment | yq '.spec.template.spec.containers[0].env[] | select(.name == "RUNNER_ROOT") | .value')" \
                          "each runner gets its own state directory"

                        # Per-runner resources override the top-level default.
                        eq "8Gi" "$(deployment | yq '.spec.template.spec.containers[1].resources.limits.memory')" \
                          "per-runner resources override"
                        eq "4Gi" "$(deployment | yq '.spec.template.spec.containers[0].resources.limits.memory')" \
                          "runners without an override get the chart default"

                        eq "20Gi" "$(deployment | yq '.spec.template.spec.volumes[] | select(.name == "nix-store") | .emptyDir.sizeLimit')" \
                          "nix store size limit comes from values"

                        # fsGroup breaks every nix unpack phase. See values.yaml.
                        eq "null" "$(deployment | yq '.spec.template.spec.securityContext.fsGroup')" \
                          "no fsGroup is ever set"
                        eq 1000 "$(deployment | yq '.spec.template.spec.securityContext.runAsUser')" \
                          "jobs run unprivileged"

                        # Both store initContainers run as root; the second is what makes
                        # the store usable by the job user.
                        eq 0 "$(deployment | yq '.spec.template.spec.initContainers[0].securityContext.runAsUser')" \
                          "store seeding runs as root"
                        eq "chown -R 1000:1000 /mnt/nix && chmod g-s /mnt/nix" \
                          "$(deployment | yq '.spec.template.spec.initContainers[1].args[1]')" \
                          "store ownership handed to the job user"

                        eq "ConfigMap
            Deployment" "$(kinds)" "only a Deployment and the nss ConfigMap by default"
          '';
        };

        chart-render-optional-resources = mkRenderCheck {
          name = "chart-render-optional-resources";
          helmArgs = [
            "--set"
            "namespace.create=true"
            "--set"
            "auth.onePassword.enabled=true"
            "--set"
            "auth.onePassword.itemPath=vaults/VAULT/items/ITEM"
            "--set"
            "imageUpdater.rbac.enabled=true"
            "--set"
            "nss.enabled=false"
            "--set"
            "nixStore.existingClaim=nix-store"
          ];
          script = ''
                        eq "Deployment
            Namespace
            OnePasswordItem
            Role
            RoleBinding" "$(kinds)" "every optional resource is rendered when enabled"

                        eq "runner-pat" "$(yq 'select(.kind == "OnePasswordItem") | .metadata.name' "$manifests")" \
                          "the 1Password item creates the Secret the runners read"

                        eq "nix-store" \
                          "$(deployment | yq '.spec.template.spec.volumes[] | select(.name == "nix-store") | .persistentVolumeClaim.claimName')" \
                          "existingClaim replaces the emptyDir store"

                        eq "" "$(deployment | yq '.spec.template.spec.volumes[] | select(.name == "nss")')" \
                          "nss.enabled=false drops the volume"
                        eq 4 "$(deployment | yq '.spec.template.spec.containers[0].volumeMounts | length')" \
                          "nss.enabled=false drops the /etc/passwd and /etc/group mounts"
          '';
        };

        # `flakeModules.default` is what the README leads with, and nothing else
        # here evaluates it — `checks.image-evaluates` calls image.nix directly
        # and bypasses the module entirely. Evaluation IS the test: a broken
        # option or a mis-wired argument fails this derivation's instantiation.
        flake-module =
          let
            evaluated = evalConsumerFlake {
              module = {
                systems = [ "x86_64-linux" ];
                imports = [ snowplow.flakeModules.default ];
                perSystem =
                  { pkgs, ... }:
                  {
                    snowplow.images = {
                      plain = { };
                      renamed.name = "custom-name";
                      configured = {
                        extraPackages = [ pkgs.yq-go ];
                        withSkopeo = false;
                        includeNixDB = false;
                        nixSettings.substituters = [ "https://example.invalid" ];
                        env.TMPDIR = null;
                        user = {
                          uid = 1234;
                          gid = 1234;
                          home = "/home/ci";
                        };
                        labels."org.opencontainers.image.source" = "https://github.com/OWNER/REPO";
                      };
                    };
                  };
              };
            };
            built = evaluated.packages.x86_64-linux;
            drv = p: builtins.unsafeDiscardStringContext p.drvPath;
          in
          pkgs.runCommand "flake-module" { } ''
            fail() { echo "FAIL: $*" >&2; exit 1; }
            eq() { [ "$1" = "$2" ] || fail "$3 (expected '$1', got '$2')"; }

            eq "configured plain renamed" ${lib.escapeShellArg (toString (builtins.attrNames built))} \
              "one package per declared image"

            # The attribute name becomes the image name, and an explicit `name`
            # wins over it.
            eq "plain.tar.gz" ${lib.escapeShellArg built.plain.name} "attr name is the default image name"
            eq "custom-name.tar.gz" ${lib.escapeShellArg built.renamed.name} "explicit name overrides the attr name"

            # Options must actually reach mkRunnerImage: if the module dropped
            # them on the floor these two would be the same derivation.
            [ ${lib.escapeShellArg (drv built.plain)} != ${lib.escapeShellArg (drv built.configured)} ] \
              || fail "option overrides did not change the derivation"

            touch $out
          '';

        # examples/flake.nix is documentation, and documentation rots. Evaluate
        # it against the working tree rather than the published flake: `import`
        # of the file plus a locally built `snowplow` input means this tests the
        # code in this commit, offline, with no fetch of github:hcbt/snowplow.
        example-flake =
          let
            example = import ../examples/flake.nix;
            exampleInputs = {
              inherit (inputs) nixpkgs;
              inherit (inputs.nivis.inputs) flake-parts;
              inherit snowplow;
            };
            evaluated = example.outputs (
              exampleInputs
              // {
                self = {
                  inputs = exampleInputs;
                  outPath = ../examples;
                };
              }
            );
            built = evaluated.packages.x86_64-linux;
          in
          pkgs.runCommand "example-flake" { } ''
            fail() { echo "FAIL: $*" >&2; exit 1; }
            eq() { [ "$1" = "$2" ] || fail "$3 (expected '$1', got '$2')"; }

            # Both documented styles, and renderChart, must still evaluate.
            eq "ci-runner other-runner runner-manifests" \
              ${lib.escapeShellArg (toString (builtins.attrNames built))} \
              "every package the example documents"

            eq "ci-runner.tar.gz" ${lib.escapeShellArg built.ci-runner.name} "flakeModules style"
            eq "other-runner.tar.gz" ${lib.escapeShellArg built.other-runner.name} "raw mkRunnerImage style"
            eq "snowplow-manifests.yaml" ${lib.escapeShellArg built.runner-manifests.name} "renderChart"

            echo ${lib.escapeShellArg (builtins.unsafeDiscardStringContext built.runner-manifests.drvPath)}
            touch $out
          '';
      }
      # Evaluating the image is the test: it proves the derivation and every
      # option path is well-formed, without pulling ~2G of closure into a check.
      # `nix build .#runner-image` in CI is what proves it builds.
      // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        image-evaluates =
          let
            mkRunnerImage = args: import ./image.nix args;
            variants = [
              (mkRunnerImage { inherit pkgs; })
              (mkRunnerImage {
                inherit pkgs;
                name = "custom";
                withSkopeo = false;
                includeNixDB = false;
                extraPackages = [ pkgs.yq-go ];
                nixSettings.substituters = [
                  "https://cache.nixos.org"
                  "https://devenv.cachix.org"
                ];
                env.TMPDIR = null;
                user = {
                  uid = 1234;
                  gid = 1234;
                  home = "/home/ci";
                };
                labels."org.opencontainers.image.source" = "https://github.com/OWNER/REPO";
              })
            ];
          in
          pkgs.runCommand "image-evaluates" { } ''
            ${lib.concatMapStringsSep "\n" (
              d: "echo ${lib.escapeShellArg (builtins.unsafeDiscardStringContext d.drvPath)}"
            ) variants}
            touch $out
          '';
      };
    };
}
