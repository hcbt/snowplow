# Tests. All offline: `helm template` needs no cluster, and every assertion runs
# against the rendered YAML with yq rather than grep — the templates carry long
# comments that survive into the output, so a grep for `--ephemeral` matches a
# comment about ephemeral runners whether or not the flag is there.
{ inputs }:
{ pkgs, lib }:
let
  chart = ../chart;
  exampleValues = ../examples/values-example.yaml;

  # The runner's bundled internal node. Imported directly rather than
  # reached for inside the built image: it is only meaningfully tested by
  # RUNNING it, and building the image to do that would pull ~2G of closure
  # into every `nix flake check`.
  #
  # /usr/bin/env used to be tested here too. It is coldstart's shim now, and
  # coldstart's `usr-bin-env-runs-scripts` covers it; `ci.yml` still probes
  # both inside the loaded image.
  shims = import ./image-shims.nix { inherit pkgs; };

  # `nix flake check` does not look at `flake.lib` or `flake.flakeModules`
  # ("The following flake outputs are unchecked"), so the consumer-facing
  # half of this repo is only covered by the two checks that use these.
  snowplow = import ./lib.nix { inherit lib inputs; };

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
    inputs.flake-parts.lib.mkFlake { inputs = allInputs; } module;

  # Stands in for Runner.Listener so the container command can be RUN, not
  # merely inspected. The rendered script is the only thing deciding whether
  # a finished job costs a kubelet restart, and no amount of yq on the
  # manifest can tell you that — so `chart-runner-supervision` executes it
  # against this, with the real binary's two subcommands faked.
  #
  # Every invocation appends to $FAKE_LOG, which is what the assertions read.
  fakeListener = pkgs.writeShellScript "Runner.Listener" ''
    case "$1" in
      configure)
        # A workspace still holding the previous job's marker would mean the
        # per-job wipe was lost when the loop replaced the restart.
        if [ -e "$RUNNER_ROOT/leftover" ]; then
          echo "dirty" >> "$FAKE_LOG"
        fi
        echo "configure" >> "$FAKE_LOG"
        if [ "''${FAKE_CONFIGURE_FAIL:-0}" = 1 ]; then
          exit 1
        fi
        exit 0
        ;;
      run)
        echo "run" >> "$FAKE_LOG"
        touch "$RUNNER_ROOT/leftover"
        if [ "''${FAKE_RUN_TRAP:-0}" = 1 ]; then
          # A job in flight: stay up until signalled, and record the signal.
          trap 'echo "listener-term" >> "$FAKE_LOG"; exit 143' TERM
          sleep 60 &
          wait $!
          exit 0
        fi
        sleep "''${FAKE_RUN_SECONDS:-0.2}"
        exit "''${FAKE_RUN_EXIT:-0}"
        ;;
      *)
        echo "unexpected subcommand: $1" >&2
        exit 64
        ;;
    esac
  '';

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

        if helm template test ${chart} --namespace ci --values ${exampleValues} \
             --set runnerBinary= > /dev/null 2>&1; then
          echo "FAIL: chart rendered a container command with no Runner.Listener" >&2
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

                  # Registration flags, read out of the container command
                  # itself — with comment lines stripped first. The command
                  # explains at length why it supervises rather than execs,
                  # and the word "--ephemeral" appears in that prose; match
                  # the raw block and every assertion below silently tests
                  # the comments instead of the code.
                  command() {
                    deployment | yq ".spec.template.spec.containers[$1].args[1]" \
                      | grep -v '^[[:space:]]*#'
                  }

                  repoArgs="$(command 0)"
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

                  orgArgs="$(command 1)"
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

                  # The supervision loop's knobs must come from values
                  # rather than being baked into the template.
                  case "$repoArgs" in
                    *"max_failures=5"*) ;;
                    *) fail "restart.maxFailures not reaching the container command" ;;
                  esac
                  case "$repoArgs" in
                    *"retry_delay=10"*) ;;
                    *) fail "restart.retryDelaySeconds not reaching the container command" ;;
                  esac
                  case "$repoArgs" in
                    *'"/bin/Runner.Listener" configure'*) ;;
                    *) fail "runnerBinary not reaching the container command" ;;
                  esac
                  # `exec` handed the container over to a single listener,
                  # so one job ended the container and the kubelet's
                  # backoff became the job queue. See
                  # checks.chart-runner-supervision for the behaviour.
                  case "$repoArgs" in
                    *"exec "*) fail "the container execs the listener instead of supervising it" ;;
                  esac

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

  # The container command can only be tested by RUNNING it. Asserting on
  # the rendered string would pass just as happily for the
  # `exec Runner.Listener` version this replaced — and that version is the
  # bug: an ephemeral listener exits 0 after one job, `restartPolicy:
  # Always` cannot tell that from a crash, and the kubelet's backoff grows
  # toward five minutes with every job. What follows are properties of the
  # script's control flow.
  chart-runner-supervision =
    pkgs.runCommand "chart-runner-supervision"
      {
        nativeBuildInputs = [
          pkgs.kubernetes-helm
          pkgs.yq-go
        ];
      }
      ''
        export HELM_CACHE_HOME="$TMPDIR/cache" HELM_CONFIG_HOME="$TMPDIR/config" HELM_DATA_HOME="$TMPDIR/data"

        fail() { echo "FAIL: $*" >&2; exit 1; }
        eq() { [ "$1" = "$2" ] || fail "$3 (expected '$1', got '$2')"; }

        # `runnerBinary` with no slash resolves through PATH, which is how
        # the fake gets in front of a binary that does not exist here.
        render() {
          helm template test ${chart} --namespace ci --values ${exampleValues} \
            --set runnerBinary=Runner.Listener "$@" \
            | yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[0].args[1]'
        }

        mkdir -p "$TMPDIR/bin"
        ln -s ${fakeListener} "$TMPDIR/bin/Runner.Listener"
        export PATH="$TMPDIR/bin:$PATH"
        export GITHUB_PAT="not-a-real-token"

        render > "$TMPDIR/loop.sh"

        # 1. A completed job must not exit the container. Under
        #    restartPolicy: Always every exit is a restart, and restarts
        #    are rate-limited — which is the whole defect.
        export RUNNER_ROOT="$TMPDIR/root-loop" FAKE_LOG="$TMPDIR/log-loop"
        : > "$FAKE_LOG"
        rc=0
        timeout -s KILL 5 bash "$TMPDIR/loop.sh" > "$TMPDIR/out-loop" 2>&1 || rc=$?
        eq 137 "$rc" "the container exited by itself after a completed job instead of looping"

        registrations=$(grep -c '^configure$' "$FAKE_LOG" || true)
        [ "$registrations" -ge 3 ] \
          || fail "expected a fresh registration per job, got $registrations in 5s"
        # SIGKILL lands at an arbitrary point, so the final iteration can
        # be torn between its `configure` and its `run`. That is an
        # artefact of how this check stops the loop, not a defect in the
        # loop: the invariant is that no registration is ever skipped or
        # doubled, which allows runs to trail registrations by at most the
        # one iteration the kill interrupted. Asserting strict equality
        # made this check fail roughly one run in ten.
        runs=$(grep -c '^run$' "$FAKE_LOG" || true)
        [ "$runs" -eq "$registrations" ] || [ "$runs" -eq "$((registrations - 1))" ] \
          || fail "every registration must be followed by exactly one listener run (registrations=$registrations runs=$runs)"
        eq 0 "$(grep -c '^dirty$' "$FAKE_LOG" || true)" \
          "the per-job workspace wipe was lost"

        # 2. A runner that can never register must still crash — that is
        #    how a PAT missing a repository announces itself — but only
        #    after restart.maxFailures, never on the first refusal, and
        #    never by spinning against api.github.com forever.
        render --set restart.maxFailures=3 --set restart.retryDelaySeconds=0 > "$TMPDIR/fail.sh"
        export RUNNER_ROOT="$TMPDIR/root-fail" FAKE_LOG="$TMPDIR/log-fail" FAKE_CONFIGURE_FAIL=1
        : > "$FAKE_LOG"
        rc=0
        timeout -s KILL 30 bash "$TMPDIR/fail.sh" > "$TMPDIR/out-fail" 2>&1 || rc=$?
        eq 1 "$rc" "a runner that cannot register must exit non-zero rather than retry forever"
        eq 3 "$(grep -c '^configure$' "$FAKE_LOG" || true)" \
          "gives up after exactly restart.maxFailures attempts"
        eq 0 "$(grep -c '^run$' "$FAKE_LOG" || true)" \
          "no listener may start when registration failed"
        unset FAKE_CONFIGURE_FAIL

        # 3. SIGTERM must reach the listener. The command used to exec it,
        #    so the kubelet's TERM landed on it directly; a supervising
        #    shell that swallows the signal leaves the job running until
        #    terminationGracePeriodSeconds expires and SIGKILL abandons it.
        export RUNNER_ROOT="$TMPDIR/root-term" FAKE_LOG="$TMPDIR/log-term" FAKE_RUN_TRAP=1
        : > "$FAKE_LOG"
        bash "$TMPDIR/loop.sh" > "$TMPDIR/out-term" 2>&1 &
        supervisor=$!
        # Turns a hang into a failed assertion instead of a stuck build.
        ( sleep 30; kill -KILL "$supervisor" 2>/dev/null ) &
        watchdog=$!

        for _ in $(seq 1 200); do
          if grep -q '^run$' "$FAKE_LOG" 2>/dev/null; then break; fi
          sleep 0.1
        done
        grep -q '^run$' "$FAKE_LOG" || fail "the listener never started"

        kill -TERM "$supervisor"
        rc=0
        wait "$supervisor" || rc=$?
        kill "$watchdog" 2>/dev/null || true

        eq 0 "$rc" "SIGTERM must shut the supervisor down cleanly and promptly"
        grep -q '^listener-term$' "$FAKE_LOG" \
          || fail "SIGTERM was not forwarded to the in-flight listener"
        eq 1 "$(grep -c '^run$' "$FAKE_LOG" || true)" \
          "a new job was started after SIGTERM"

        touch $out
      '';

}
# Evaluating the image is the test: it proves the derivation and every
# option path is well-formed, without pulling ~2G of closure into a check.
# `nix build .#runner-image` in CI is what proves it builds.
// lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
  # `hashFiles()` is not evaluated in-process: the runner spawns its
  # internal node on `hashFiles/index.js` and reads the digest back off
  # stderr. So this runs that exact command, resolving the node the
  # same way HashFilesFunction does — from the runner's own directory —
  # and then changes the file to prove the digest is a hash of the
  # contents and not a constant. Asserting `externals/node20` merely
  # exists would pass for a dangling symlink, and asserting on the
  # image's file list would pass for a node that cannot run the
  # script.
  #
  # Linux-only for the same reason as image-evaluates: github-runner is
  # substitutable there, and this must not become a dotnet build on a
  # laptop.
  hashfiles-evaluates =
    let
      runner = shims.withInternalNode pkgs.github-runner;
    in
    pkgs.runCommand "hashfiles-evaluates" { } ''
      fail() { echo "FAIL: $*" >&2; exit 1; }

      # <runner root>/externals/<internal version>/bin/node, where the
      # runner root is the parent of the directory Runner.Worker lives
      # in. Not $out/bin: the worker never goes through the wrappers.
      root=${runner}/lib
      node="$root/externals/node20/bin/node"
      [ -x "$node" ] || fail "no internal node at $node"

      # The script is a directory; node resolves index.js inside it.
      # Patterns arrive in $patterns, the cwd is the workspace, and the
      # digest comes back on stderr between __OUTPUT__ markers.
      hash_of() {
        printf '%s' "$1" > "$workspace/hashed"
        ( cd "$workspace" && patterns="hashed" "$node" "$root/github-runner/hashFiles" 2>&1 ) \
          | sed -n 's/.*__OUTPUT__\(.*\)__OUTPUT__.*/\1/p'
      }

      workspace=$PWD/workspace
      mkdir -p "$workspace"

      first=$(hash_of hello)
      printf '%s' "$first" | grep -Eq '^[0-9a-f]{64}$' \
        || fail "hashFiles() produced no digest (got '$first')"

      second=$(hash_of world)
      [ "$first" != "$second" ] \
        || fail "hashFiles() returned the same digest for different contents"

      touch $out
    '';

  image-evaluates =
    let
      mkRunnerImage = args: import ./image.nix { inherit (inputs.coldstart.lib) mkImage; } args;
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
}
