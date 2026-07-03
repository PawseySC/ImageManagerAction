# ImageManagerAction Workflow Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the self-contradictions, dead code, and unhandled edge cases from the GitHub Actions CI/CD suite so the pipeline's behaviour is consistent, documented, and reliable.

**Architecture:** The pipeline stays exactly as it is (PREPARE → BUILD → SCAN/TEST → PUSH_PRIV/PUSH_PUBLIC → DEPLOY → SUMMARY → MERGE_TO_MAIN/CLEANUP_BRANCH, driven by `manifest.json` on `cicd-{main}/{feature}` branches). We fix behaviour *within* that shape: fail-fast validation, graceful skips for empty target lists, correct digest pinning, deduplicated shell helpers, deterministic action resolution (explicit checkouts), and docs that match reality.

**Tech Stack:** GitHub Actions (reusable workflows + composite actions), bash, jq, podman, rclone, Trivy.

## Global Constraints

- Repo root: `/home/ubuntu/code/Image/ImageManagerAction`. Work on branch `improve/actions`. Commit after each task; do NOT push.
- Commit messages: conventional style (`fix(ci): …`, `refactor(ci): …`, `docs: …`). Do NOT add any Co-Authored-By trailer.
- After every task run the linter and fix everything it reports for files you touched:
  `/tmp/claude-1000/-home-ubuntu-code-Image/8bda7558-df45-4ed2-afc9-d0134fc9eb7a/scratchpad/bin/actionlint -color` (run from repo root; shellcheck is installed and actionlint uses it on `run:` blocks). Pre-existing warnings in files you did NOT touch may be left alone but must be listed in your report.
- Behaviour contract that must NOT change: matrix `image_name`/`variant_suffix` values, S3 object names (`{image_name}_{version}.tar/.sif`), registry ref formats, `summary.json` schema (field additions allowed, no renames/removals), branch/merge/cleanup semantics except where a task says otherwise.
- The `version` value everywhere downstream of PREPARE already includes the platform suffix (`X.Y.Z-x86` / `X.Y.Z-arm`). Keep it that way.
- YAML `run:` heredoc gotcha: all lines of a `run: |` block share the same base indentation; a heredoc terminator must sit at that base indentation (existing files follow this — keep the pattern).

---

### Task 1: Remove dead code and vestigial steps

**Files:**
- Delete: `.github/workflows/docker-ci.yml.backup`
- Modify: `.github/workflows/reusable-prepare.yml`
- Modify: `.github/workflows/reusable-build.yml`
- Modify: `.github/workflows/reusable-summary.yml`
- Modify: `.github/workflows/ci-dispatch.yml`

**Interfaces:**
- Produces: BUILD no longer exposes `image_tag`/`image_name` workflow outputs; SUMMARY no longer takes `image_name` input; PREPARE no longer exposes `date` or `dockerhub_available` outputs. No consumer of any of these exists after this task (verified by grep beforehand — `date` and `dockerhub_available` are consumed by nothing today, `image_name` is declared in SUMMARY but never referenced in its body).

- [ ] **Step 1: Delete the 1809-line legacy backup workflow**

```bash
git rm .github/workflows/docker-ci.yml.backup
```

- [ ] **Step 2: `reusable-prepare.yml` — remove the `date` output and step, and all Docker Hub vestiges**

Remove:
- workflow_call outputs block entry `date:` (lines 63-65) and job outputs entry `date: ${{ steps.date.outputs.date }}` (line 109).
- The whole `Generate date tag` step (lines 446-452).
- workflow_call outputs entry `dockerhub_available:` (lines 66-68) and job outputs entry (line 110).
- In step `check_vars_secrets`: the `DOCKERHUB_USERNAME` missing-vars check, the `DOCKERHUB_TOKEN` missing-secrets check, the `dockerhub_available=$(…)` line, its `>> $GITHUB_OUTPUT` line, and the `[✓]/[✗] Docker Hub` log block.
- workflow_call secrets entry `DOCKERHUB_TOKEN:` (it is unused after this).

- [ ] **Step 3: `reusable-build.yml` — remove racy matrix outputs and the no-op cache step**

- Remove the workflow_call `outputs:` block (lines 41-47) and the job-level `outputs:` block (lines 58-60). (Matrix jobs overwrite job outputs nondeterministically — last variant wins — and nothing consumes them after this task.)
- In step `compute_variant`: remove the duplicated second `echo "VARIANT_SUFFIX=$VARIANT_SUFFIX" >> $GITHUB_ENV` (line 100; keep the one at line 87).
- Remove the entire `Initialize build cache` step (`id: setup_cache`, lines 229-265).
- In `setup_env`: remove the `IMAGE_CACHE_REF` lines (200, 210, 227) — keep the JOBS logic untouched.
- In `build_container`: remove the "Set up cache tracking" block (lines 286-296: `CACHE_KEY=…`, `IMAGE_CACHE_REF=…`, the `if [ -d "${REGISTRY_CACHE_DIR}…` check) and, in the post-build success branch, remove the `mkdir -p "${REGISTRY_CACHE_DIR}/${CACHE_KEY}"` + `echo "$(date): Built …" >> …/build.log` lines and the `echo "Cache reference: $IMAGE_CACHE_REF"` / `[CACHE DIRECTORY]` echo lines.
- Replace the weak verification

```bash
          if podman images | grep -q "${image_name}"; then
```

with

```bash
          if podman image exists "$image_tag"; then
```

(keep the success-branch echoes minus the cache lines; keep the failure branch).

- [ ] **Step 4: `reusable-summary.yml` + `ci-dispatch.yml` — drop the dead `image_name` input**

- In `reusable-summary.yml`: remove the `image_name:` input declaration (lines 30-32). (Grep confirms `inputs.image_name` appears nowhere in the body.)
- In `ci-dispatch.yml` SUMMARY job: remove the line `image_name: ${{ needs.BUILD.outputs.image_name }}`.

- [ ] **Step 5: Lint**

Run actionlint (see Global Constraints). Expected: no NEW findings in touched files.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "refactor(ci): remove dead outputs, legacy backup workflow, and no-op cache step"
```

---

### Task 2: PREPARE fails loudly on invalid manifest; drop the phantom legacy branch format

**Files:**
- Modify: `.github/workflows/reusable-prepare.yml`
- Modify: `.github/workflows/ci-dispatch.yml` (header comment only)

**Why:** Today an invalid manifest sets `proceed_valid=false` and `exit 0` → every job skips and the run ends **green**, then CLEANUP_BRANCH silently deletes the branch. The uploader gets zero signal. Also the header claims a legacy `cicd-main-feature` format is supported, but the later `branch_path == main/feature` check makes that format impossible (expected_path always contains `/`) — a self-contradiction.

**Interfaces:**
- Produces: on any validation failure, the PREPARE job FAILS (red run) with a `::error::` annotation; `proceed_valid` is never set to `false` anymore (downstream `if:` guards keep working because a failed/empty output ≠ `'true'`, and dependent jobs skip anyway when a needed job fails). CLEANUP_BRANCH still deletes the branch afterwards (it only requires MERGE_TO_MAIN==skipped and !cancelled()).

- [ ] **Step 1: Add a fail helper and convert all 8 `proceed_valid=false; exit 0` sites**

At the top of the `validate_manifest` step's script insert:

```bash
          fail() {
            echo "::error title=Manifest validation failed::$1"
            exit 1
          }
```

Then replace every occurrence of the pattern

```bash
          echo "Error: <message>"
          echo "proceed_valid=false" >> $GITHUB_OUTPUT
          exit 0
```

with a single `fail "<same message>"` call, keeping any preceding context `echo`s that help debugging (e.g. the "Searched for:" line can be folded into the message). Sites: missing manifest.json, no Dockerfile found, missing `main`, missing `feature`, missing `version`, bad semver, bad platform, branch-path mismatch.

- [ ] **Step 2: Remove the legacy dash-format pretense in `parse_branch`**

Replace the body of the `if/else` on slash detection with: if `$path_part` contains `/`, use it; else `fail`-style error:

```bash
          if [[ "$path_part" == *"/"* ]]; then
            branch_path="$path_part"
          else
            echo "::error title=Bad branch name::Branch must be named cicd-<main>/<feature> (got '${branch_name}'). The dash format cicd-main-feature is not supported: the manifest cross-check requires main/feature."
            exit 1
          fi
```

(Define nothing extra; a direct echo+exit is fine here.) Remove the stale comments about the legacy format in this step.

- [ ] **Step 3: Update header comments**

- `reusable-prepare.yml` — no header comment exists; nothing to do beyond step 2's inline comments.
- `ci-dispatch.yml` line 5: change `# Supports branch formats: cicd-main/feature (preferred) or cicd-main-feature (legacy)` to `# Branch format: cicd-<main>/<feature> (the dash form cicd-main-feature is NOT supported)`.

- [ ] **Step 4: Lint + commit**

```bash
git add -A && git commit -m "fix(ci): fail PREPARE loudly on invalid manifest; drop unsupported legacy branch format"
```

---

### Task 3: Handle empty `private-targets` gracefully

**Files:**
- Modify: `.github/workflows/ci-dispatch.yml`
- Modify: `.github/workflows/reusable-push-priv.yml`
- Modify: `.github/workflows/reusable-summary.yml`

**Why:** With `private-targets: []` in the manifest and Setonix creds present, the push step currently hits `Error: No private targets found in manifest; exit 1` → the whole run fails and the branch is deleted. Job-level treats private push as optional; step-level treats "nothing to do" as fatal. Contradiction.

**Interfaces:**
- Produces: `PUSH_PRIV` is *skipped* when `private_targets == '[]'`; `MERGE_TO_MAIN` accepts `skipped` for PUSH_PRIV (mirroring how it already accepts skipped PUSH_PUBLIC/DEPLOY); SUMMARY renders "skipped (no private target)" instead of "failed".

- [ ] **Step 1: Gate the job in `ci-dispatch.yml`**

```yaml
  PUSH_PRIV:
    needs: [PREPARE, BUILD]
    # Skip entirely when the manifest names no private target — an empty list is
    # a valid configuration (public-only build), not an error.
    if: |
      needs.PREPARE.outputs.proceed_valid == 'true' &&
      needs.PREPARE.outputs.private_targets != '[]' &&
      needs.PREPARE.outputs.private_targets != ''
```

- [ ] **Step 2: Accept the skip in MERGE_TO_MAIN**

Change the condition line

```yaml
      needs.PUSH_PRIV.result == 'success' &&
```

to

```yaml
      (needs.PUSH_PRIV.result == 'success' || needs.PUSH_PRIV.result == 'skipped') &&
```

- [ ] **Step 3: Defense in depth inside `reusable-push-priv.yml`**

In the `Push to Setonix private registry` step replace

```bash
        if [ -z "$private_username" ] || [ "$private_username" = "null" ]; then
          echo "Error: No private targets found in manifest"; exit 1
        fi
```

with

```bash
        if [ -z "$private_username" ] || [ "$private_username" = "null" ]; then
          echo "No private targets in manifest — nothing to push (this job is normally skipped upstream)."
          exit 0
        fi
```

- [ ] **Step 4: SUMMARY renders the skip correctly**

- Markdown template branch (`Generate registry block`, template case): the `Setonix Private Registry` section currently keys only off `setonixreg_available` + `result_push_priv`. Add a first branch: if `[ "${{ inputs.result_push_priv }}" = "skipped" ]` → `echo "### Setonix Private Registry — ⏭️ skipped (no private target selected)"`.
- Non-template table: same — before the existing available/failed checks, if result is `skipped` emit `| Setonix Private | — | ⏭️ Skipped (no private target) |`.
- `summary.json` step: change the `priv_result` computation to

```bash
          priv_result="skipped"
          if [ "$RESULT_PUSH_PRIV" = "skipped" ]; then priv_result="skipped"
          elif [ "$SETONIXREG_AVAILABLE" = "true" ] && [ "$RESULT_PUSH_PRIV" = "success" ]; then priv_result="success"
          elif [ "$SETONIXREG_AVAILABLE" = "true" ]; then priv_result="failed"; fi
```

- Job-results table row for PUSH-PRIV already renders `⏭️ Skipped` — no change.

- [ ] **Step 5: Lint + commit**

```bash
git add -A && git commit -m "fix(ci): skip PUSH_PRIV cleanly when manifest has no private targets"
```

---

### Task 4: Explicit checkout wherever local composite actions are used

**Files:**
- Modify: `.github/workflows/reusable-scan.yml`
- Modify: `.github/workflows/reusable-push-priv.yml`
- Modify: `.github/workflows/reusable-push-public.yml`

**Why:** These jobs call `uses: ./.github/actions/setup-rclone` without checking out the repo. They only work because the self-hosted runner's per-repo workspace still contains a checkout from a *previous* job — possibly from a *different branch/commit* (workspace is per-repo, not per-branch). That's a latent wrong-version-of-the-action bug and breaks on any fresh runner.

- [ ] **Step 1: Add as the FIRST step of each of the three jobs**

```yaml
    - name: Checkout (required to resolve local composite actions)
      uses: actions/checkout@v6
      with:
        fetch-depth: 1
```

(reusable-test.yml and reusable-build.yml already check out; reusable-deploy.yml uses no local actions — leave both alone.)

- [ ] **Step 2: Lint + commit**

```bash
git add -A && git commit -m "fix(ci): check out repo in scan/push jobs so local actions resolve at the right commit"
```

---

### Task 5: setup-rclone — install once, drop the five inconsistent ensure_rclone copies

**Files:**
- Modify: `.github/actions/setup-rclone/action.yml`
- Check/adjust: `.github/actions/setup-rclone/README.md` (update if it documents the old behaviour)

**Why:** `ensure_rclone()` is pasted 5× with *different* capabilities (only two copies know the static-download fallback). The first step already persists the static binary via `$GITHUB_PATH`; module-provided rclone, however, vanishes between steps — that's why the copies exist. Fix the root cause: resolve rclone ONCE, persist its directory to `$GITHUB_PATH`, and let every later step just call `rclone`.

- [ ] **Step 1: Rewrite the `Load rclone module` step**

Keep the same 4-method cascade, but end every success path with:

```bash
        RCLONE_BIN=$(command -v rclone)
        echo "$(dirname "$RCLONE_BIN")" >> "$GITHUB_PATH"
        echo "✓ rclone at $RCLONE_BIN (dir persisted to GITHUB_PATH)"
        rclone version
        echo "loaded=true" >> $GITHUB_OUTPUT
        exit 0
```

Implementation shape (replace the whole step script):

```bash
        set +e
        find_rclone() {
          command -v rclone >/dev/null 2>&1 && return 0
          module load rclone/1.68.1 2>/dev/null && command -v rclone >/dev/null 2>&1 && return 0
          module load spack 2>/dev/null && spack load rclone 2>/dev/null && command -v rclone >/dev/null 2>&1 && return 0
          case "$(uname -m)" in
            aarch64|arm64) RARCH=arm64 ;;
            x86_64|amd64)  RARCH=amd64 ;;
            *) return 1 ;;
          esac
          RBIN="${RUNNER_TEMP:-/tmp}/rclone-bin"
          mkdir -p "$RBIN"
          curl -fsSL "https://downloads.rclone.org/rclone-current-linux-${RARCH}.zip" -o "$RBIN/rclone.zip" \
            && unzip -o -j "$RBIN/rclone.zip" '*/rclone' -d "$RBIN" >/dev/null \
            && chmod +x "$RBIN/rclone" || return 1
          export PATH="$RBIN:$PATH"
          command -v rclone >/dev/null 2>&1
        }
        if find_rclone; then
          RCLONE_BIN=$(command -v rclone)
          echo "$(dirname "$RCLONE_BIN")" >> "$GITHUB_PATH"
          echo "✓ rclone at $RCLONE_BIN"
          rclone version
          echo "loaded=true" >> $GITHUB_OUTPUT
        else
          echo "::error::rclone unavailable (PATH, Setonix module, spack, static download all failed)"
          exit 1
        fi
```

- [ ] **Step 2: Delete every `ensure_rclone()` definition + call in the other steps** (`Configure rclone`, `Verify rclone Configuration`, `Debug S3 Connection`, `Download archive from S3`, `Upload file to S3 storage`). Each step begins directly with its real work; add a one-line guard `command -v rclone >/dev/null || { echo "::error::rclone missing from PATH"; exit 1; }` at the top of each.

- [ ] **Step 3: Stop interpolating secrets into the config heredoc**

In `Configure rclone (local config)` add a step-level `env:` block:

```yaml
      env:
        S3_ENDPOINT: ${{ inputs.endpoint }}
        S3_ACCESS_KEY_ID: ${{ inputs.access_key_id }}
        S3_SECRET_ACCESS_KEY: ${{ inputs.secret_access_key }}
```

and write the config from those variables (`endpoint = ${S3_ENDPOINT}` etc. — heredoc unquoted so vars expand).

- [ ] **Step 4: Lint + commit**

```bash
git add -A && git commit -m "refactor(rclone-action): resolve rclone once via GITHUB_PATH, drop 5 divergent ensure_rclone copies"
```

---

### Task 6: DRY the podman env + retry helpers

**Files:**
- Create: `.github/actions/podman-env/action.yml`
- Create: `.github/scripts/retry.sh`
- Modify: `.github/workflows/reusable-build.yml`, `reusable-push-priv.yml`, `reusable-push-public.yml`, `reusable-test.yml`, `image-sync.yml`

**Interfaces:**
- Produces: composite action `podman-env` that exports `RID`, `XDG_DATA_HOME`, `XDG_RUNTIME_DIR`, `TMPDIR` via `$GITHUB_ENV` (identical values to today's inline blocks). `retry.sh` defines `retry <attempts> <delay_seconds> <command…>` with exponential backoff — byte-compatible semantics with the existing copies.

- [ ] **Step 1: Create `.github/actions/podman-env/action.yml`**

```yaml
name: 'Podman environment'
description: >-
  Per-runner rootless-podman isolation: multiple runners on one machine must
  never share a store. RID = stable fs-safe hash of the runner name. Exports
  RID, XDG_DATA_HOME, XDG_RUNTIME_DIR, TMPDIR via GITHUB_ENV and creates the
  directories.
runs:
  using: 'composite'
  steps:
    - name: Export per-runner podman env
      shell: bash
      run: |
        set -euo pipefail
        RID=$(printf '%s' "${RUNNER_NAME:-default}" | sha1sum | cut -c1-12)
        XDG_DATA_HOME="/container/${USER}/data-${RID}"
        XDG_RUNTIME_DIR="/container/${USER}/runtime-${RID}"
        TMPDIR="/container/${USER}/tmp-${RID}/"
        mkdir -p "$XDG_DATA_HOME" "$XDG_RUNTIME_DIR" "$TMPDIR"
        {
          echo "RID=${RID}"
          echo "XDG_DATA_HOME=${XDG_DATA_HOME}"
          echo "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR}"
          echo "TMPDIR=${TMPDIR}"
        } >> "$GITHUB_ENV"
        echo "Podman env ready (RID=${RID})"
```

- [ ] **Step 2: Create `.github/scripts/retry.sh`**

```bash
#!/usr/bin/env bash
# retry <attempts> <initial_delay_seconds> <command...>
# Exponential backoff: delay doubles after each failed attempt.
retry() {
  local attempts="$1" delay="$2" n=1
  shift 2
  until "$@"; do
    if [ "$n" -ge "$attempts" ]; then
      echo "✗ Command failed after $n attempts: $*"
      return 1
    fi
    echo "↻ Attempt $n failed; retrying in ${delay}s…"
    sleep "$delay"
    n=$((n + 1))
    delay=$((delay * 2))
  done
}
```

- [ ] **Step 3: Replace the inline copies**

- `reusable-build.yml` `Configure podman environment` step → `uses: ./.github/actions/podman-env`, followed by a slimmed `run:` step keeping ONLY the JOBS computation (CPU cores → JOBS → `$GITHUB_ENV`). The directory-existence check block is covered by the action's `mkdir -p` — drop it.
- `reusable-push-priv.yml`, `reusable-push-public.yml`, `reusable-test.yml` `Configure podman environment` steps → `uses: ./.github/actions/podman-env` (push-public keeps its step-level `if:`).
- The build retry loop in `build_container`: replace the hand-rolled `until … done` with `source .github/scripts/retry.sh` + `retry 3 15 podman build --format=docker --layers --pull=newer ${JOBS:+--jobs "$JOBS"} -f "$dockerfile_path" -t "$image_tag" "$branch_path" || { echo "✗ podman build failed after retries"; exit 1; }` (keep the explanatory comment about registry blips).
- The three `retry()` definitions in `reusable-push-public.yml` and one in `reusable-push-priv.yml` → `source .github/scripts/retry.sh` at the top of each step that used them (these jobs check out the repo as of Task 4).
- `image-sync.yml`: replace its mini `retry()` with `source .github/scripts/retry.sh` (it already checks out) — note its old backoff was `5*n` linear; the shared lib's doubling is an accepted change. Also replace its inline podman-env export block (in BOTH the mirror step and the cleanup step) with `uses: ./.github/actions/podman-env` placed before them (env persists across steps, so one use suffices; the cleanup step's re-export becomes unnecessary — delete it).

- [ ] **Step 4: Lint + commit**

```bash
git add -A && git commit -m "refactor(ci): shared podman-env composite action and retry.sh, replacing 5 inline copies"
```

---

### Task 7: DEPLOY — pin SHPC to the real manifest digest, and authenticate the fetch

**Files:**
- Modify: `.github/workflows/reusable-deploy.yml`

**Why:** Two bugs. (1) The step extracts `.config.digest` — the digest of the image *config blob* — but SHPC `tags:` must map to the **manifest digest** (what `image@sha256:…` resolves); config digests do not resolve, so installs pinned by that digest break. (2) The fetch is anonymous, but since automatic `changevisibility` was removed, a first-time quay repo is private → anonymous manifest GET fails and DEPLOY can never succeed for new images. Fix: token-authenticated fetch (quay Bearer token via the robot credentials, which are available through `secrets: inherit`), digest from the `Docker-Content-Digest` response header with a body-hash fallback.

- [ ] **Step 1: Replace the manifest-fetch block in `Determine deployment target and get SHA256 digest`**

Replace everything from `echo "Fetching manifest for tag: ${VERSION}"` down to (and including) the `echo "SHA256 digest: $digest"` line with:

```bash
          # Get a pull token. quay.io requires one even for public repos when we
          # want the Docker-Content-Digest header reliably; for repos still
          # private (visibility is no longer auto-flipped on first push) the
          # robot credentials are REQUIRED.
          echo "Fetching manifest for tag: ${VERSION}"
          token=$(curl -fsS -u "${QUAY_USER}:${QUAY_TOKEN}" \
            "https://quay.io/v2/auth?service=quay.io&scope=repository:${api_path}:pull" \
            | jq -r '.token // empty')
          if [ -z "$token" ]; then
            echo "::error::Could not obtain quay.io pull token for ${api_path}"
            exit 1
          fi

          headers_file=$(mktemp)
          manifest_response=$(curl -fsS -D "$headers_file" \
            -H "Authorization: Bearer ${token}" \
            -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
            -H "Accept: application/vnd.oci.image.manifest.v1+json" \
            -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
            -H "Accept: application/vnd.oci.image.index.v1+json" \
            "$registry_url/$api_path/manifests/${VERSION}") || {
              echo "::error::Failed to fetch manifest from $registry_url/$api_path/manifests/${VERSION}"
              exit 1
            }

          # The digest that `podman pull image@sha256:…` resolves is the MANIFEST
          # digest (Docker-Content-Digest header) — NOT .config.digest, which is
          # the digest of the config blob and does not resolve as a pull ref.
          digest=$(awk 'tolower($1)=="docker-content-digest:" {print $2}' "$headers_file" | tr -d '\r')
          if [ -z "$digest" ]; then
            digest="sha256:$(printf '%s' "$manifest_response" | sha256sum | cut -d' ' -f1)"
            echo "Docker-Content-Digest header missing; computed from body: $digest"
          fi
          rm -f "$headers_file"

          case "$digest" in
            sha256:*) ;;
            *) echo "::error::Bad digest '$digest'"; exit 1 ;;
          esac
          echo "Manifest digest: $digest"
```

And add to that step a step-level `env:` block:

```yaml
        env:
          QUAY_USER: ${{ vars.QUAYIO_USERNAME }}
          QUAY_TOKEN: ${{ secrets.QUAYIO_TOKEN }}
```

(`secrets: inherit` in ci-dispatch makes `secrets.QUAYIO_TOKEN` referenceable here without a `workflow_call.secrets` declaration; do NOT add one.)

**Caveat for the body-hash fallback:** the digest is over the EXACT bytes served; since we hash the raw `curl` body unmodified this is correct, but the header path is primary.

- [ ] **Step 2: Lint + commit**

```bash
git add -A && git commit -m "fix(deploy): pin SHPC to the manifest digest (not .config.digest) via authenticated fetch"
```

---

### Task 8: process-template — extract to a tested script, fix JSON-injection, fix the SHPC summary drift

**Files:**
- Modify: `.github/actions/process-template/action.yml`
- Create: `.github/actions/process-template/generate-matrix.sh`
- Create: `.github/actions/process-template/tests/run-tests.sh`
- Create: `.github/actions/process-template/tests/fixtures/` (3 manifest fixtures + expected outputs)
- Modify: `.github/workflows/reusable-summary.yml` (SHPC block)

**Why:** (1) The cartesian product is built by string-interpolating values into JSON (`{\"$key\": \"$val\"}`) — a template value containing `"` or `\` produces invalid JSON and a confusing failure. (2) The subshell/temp-file loop is fragile and unreadable. (3) The SHPC summary block *recomputes* variant names with its own jq (all keys, no name-template expansion) instead of using the matrix's authoritative `image_name` — names drift apart whenever a name template or constant keys exist.

**Interfaces:**
- Produces: `generate-matrix.sh MANIFEST_PATH MAIN FEATURE` prints three lines to stdout: `has_template=…`, `variant_count=…`, `matrix=…` (exact same values the current action emits — key iteration order stays **sorted** (`jq keys` order) so `index`, `variant_suffix`, and `image_name` are byte-identical for existing manifests).

- [ ] **Step 1: Write `generate-matrix.sh`**

```bash
#!/usr/bin/env bash
# generate-matrix.sh <manifest.json> <main> <feature>
# Prints GitHub-output lines: has_template=…, variant_count=…, matrix=…
set -euo pipefail

manifest_file="$1"; main="$2"; feature="$3"

sanitize() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9._-]/-/g; s/-\+/-/g; s/^[.-]*//; s/[.-]*$//'
}
base_sanitized=$(sanitize "${main}-${feature}")

# org.opencontainers.image.name may contain ${TEMPLATE_VAR} placeholders that we
# expand per variant to produce the image name (drives tar/sif filenames +
# registry tags + the catalog). Falls back to main-feature when absent.
name_tmpl=$(jq -r '.labels["org.opencontainers.image.name"] // empty' "$manifest_file")

if ! jq -e '.template' "$manifest_file" > /dev/null 2>&1; then
  # Single-variant matrix MUST still carry image_name + variant_suffix; BUILD
  # reads ${{ matrix.image_name }} and an empty value breaks the image tag.
  nt_img="$base_sanitized"
  if [ -n "$name_tmpl" ] && ! printf '%s' "$name_tmpl" | grep -q '[$]{'; then
    nt_img=$(sanitize "${base_sanitized}-${name_tmpl}")
  fi
  echo "has_template=false"
  echo "variant_count=1"
  jq -nc --arg img "$nt_img" \
    '{include: [{index: 1, values: {}, varying_keys: [], variant_suffix: "", image_name: $img}]} | "matrix=\(tojson)"' -r
  exit 0
fi

template=$(jq -c '.template' "$manifest_file")

# Cartesian product, all in jq (no shell string-splicing → values with quotes,
# spaces, or backslashes are safe). Keys iterate in SORTED order — identical to
# the old `jq keys` loop — so index/variant_suffix/image_name stay stable.
combinations=$(jq -c '
  to_entries | sort_by(.key) |
  reduce .[] as $e ([{}];
    [ .[] as $c
      | (($e.value | if type == "array" then .[] else . end) | tostring) as $v
      | ($c + {($e.key): $v}) ])
' <<< "$template")

varying_keys_json=$(jq -c '[to_entries[] | select((.value | type == "array") and (.value | length > 1)) | .key] | sort' <<< "$template")
variant_count=$(jq 'length' <<< "$combinations")

matrix_json=$(jq -c \
  --argjson vk "$varying_keys_json" \
  --arg base "$base_sanitized" \
  --arg name_tmpl "$name_tmpl" \
  '[
  to_entries[] |
  {
    index: (.key + 1),
    values: .value,
    varying_keys: $vk,
    variant_suffix: (
      .value | to_entries
      | map(select(.key as $k | $vk | contains([$k]))
            | "-" + (.key | ascii_downcase) + "-" + (.value | tostring | ascii_downcase))
      | join("")
    ),
    image_name: (
      (if ($name_tmpl | length) > 0
       then (reduce (.value | to_entries[]) as $e ($name_tmpl;
               gsub("\\$\\{" + $e.key + "\\}"; ($e.value | tostring))))
       else "" end) as $expanded |
      if (($name_tmpl | length) > 0) and (($expanded | test("\\$\\{")) | not)
      then (
        ($base + "-" + $expanded + (
          .value | to_entries
          | map(select(.key as $k
                       | ($vk | contains([$k]))
                         and (($name_tmpl | test("\\$\\{" + $k + "\\}")) | not)))
          | map("-" + (.key | ascii_downcase) + "-" + (.value | tostring | ascii_downcase))
          | join("")))
        | ascii_downcase | gsub("[^a-z0-9._-]"; "-") | gsub("-+"; "-")
        | gsub("^[.-]+"; "") | gsub("[.-]+$"; "")
      )
      else (
        $base + (
          .value | to_entries
          | map(select(.key as $k | $vk | contains([$k]))
                | "-" + (.key | ascii_downcase) + "-" + (.value | tostring | ascii_downcase))
          | join(""))
      )
      end
    )
  }
] | {include: .}' <<< "$combinations")

echo "has_template=true"
echo "variant_count=$variant_count"
echo "matrix=$matrix_json"
```

Notes for the implementer:
- The old shell path coerced every value to a *string* via `jq -r`; `tostring` in the reduce preserves that (numbers like `3.12` stay `"3.12"`).
- `values: .value` therefore contains string values only — same as before.
- Mark executable: `chmod +x`.

- [ ] **Step 2: Slim `action.yml` to call the script**

The `Generate matrix from template` step body becomes:

```bash
        set -euo pipefail
        "${GITHUB_ACTION_PATH}/generate-matrix.sh" \
          "${{ inputs.manifest_path }}" "${{ inputs.main }}" "${{ inputs.feature }}" \
          | tee -a "$GITHUB_OUTPUT"
```

(The script prints exactly the three `key=value` output lines; `tee -a` both logs and sets them. `dockerfile_path` input is unused by the logic — remove that input AND its caller line in `reusable-prepare.yml`'s `process_template` step.)

- [ ] **Step 3: Golden tests**

`tests/fixtures/`:
1. `no-template.json`: `{"main":"ex1","feature":"base","labels":{}}` → expect `has_template=false`, matrix with `image_name":"ex1-base"`.
2. `template-basic.json`: `{"main":"python","feature":"cuda","template":{"CUDA_VERSION":["12.4","12.6"],"PY":"3.12"}}` → 2 variants; suffixes `-cuda_version-12.4` / `-cuda_version-12.6`; image names `python-cuda-cuda_version-12.4` etc.; `varying_keys=["CUDA_VERSION"]`.
3. `template-name-label.json`: `{"main":"mpi","feature":"gpu","labels":{"org.opencontainers.image.name":"rocm${ROCM}"},"template":{"ROCM":["5.7","6.1"],"FLAGS":"-O2 --with-x \"quoted\""}}` → verifies quote/space safety and name-template expansion (image names `mpi-gpu-rocm5.7`, `mpi-gpu-rocm6.1`).

`tests/run-tests.sh`: for each fixture run `generate-matrix.sh`, extract the `matrix=` line, and `jq -e` assert: variant_count, `.include | length`, each `image_name`, each `variant_suffix`, and that `jq empty` parses (valid JSON). Exit non-zero on any mismatch; print PASS/FAIL per fixture. **Before writing expected values for fixtures 1–2, run the OLD action logic mentally against the spec above — expected values are stated here; use them.** Fixture 3's old behaviour was BROKEN (invalid JSON from the quote) — the expectation encodes the new, correct behaviour.

- [ ] **Step 4: Run the tests**

```bash
bash .github/actions/process-template/tests/run-tests.sh
```
Expected: `PASS` ×3.

- [ ] **Step 5: Fix the SHPC block in `reusable-summary.yml`**

Replace the variant-listing jq (the `while read variant; do … done < <(echo "$matrix_json" | jq -r '.include[] | .values | …')` block) with the authoritative names:

```bash
                while read -r vimg; do
                  echo "- \`quay.io/pawsey/${vimg}:${VERSION}\`" >> /tmp/shpc_block.txt
                done < <(echo "$matrix_json" | jq -r '.include[].image_name')
```

(Delete the old `to_entries | map("-"+…)` jq entirely — it listed non-varying keys and ignored the name template, so the summary showed names that don't exist.)

- [ ] **Step 6: Lint + commit**

```bash
git add -A && git commit -m "refactor(process-template): tested pure-jq matrix generation; fix SHPC summary name drift"
```

---

### Task 9: SCAN — drop the phantom SARIF path, pin trivy-action, harden the report script

**Files:**
- Modify: `.github/workflows/reusable-scan.yml`
- Modify: `.github/workflows/ci-dispatch.yml`

**Why:** The dispatcher grants `security-events: write` "for uploading SARIF results", but no job ever uploads SARIF to GitHub — the SARIF file just lands in an artifact next to the JSON that already feeds the web summary. Generating it costs a second full Trivy pass. The action is pinned to `@master` (unreproducible). The report post-processing interpolates shell variables inside an inline `python3 -c "…"` string (quoting bomb).

- [ ] **Step 1: Remove the SARIF step** (`Generate security report (SARIF)`, lines 228-245) from `reusable-scan.yml`.

- [ ] **Step 2: In `ci-dispatch.yml`** remove `security-events: write  # Required for uploading SARIF results to GitHub Security tab` from `permissions:` (keep `contents: read` and `actions: read`).

- [ ] **Step 3: Pin trivy-action**

```bash
curl -fsS https://api.github.com/repos/aquasecurity/trivy-action/releases/latest | jq -r .tag_name
```

Replace `aquasecurity/trivy-action@master` with `aquasecurity/trivy-action@<that tag>` in the remaining (JSON) scan step. Add comment `# renovate: pin to release tag — @master is not reproducible`.

- [ ] **Step 4: Convert the inline `python3 -c` report script to a heredoc**

Same logic, but passed via stdin with env vars instead of shell interpolation:

```yaml
    - name: Process scan results to summary
      env:
        JSON_FILE: ${{ env.REPORT_DIR }}/scan-results.json
        SUMMARY_FILE: ${{ env.REPORT_DIR }}/summary.md
        COUNTS_FILE: ${{ env.REPORT_DIR }}/scan-counts.json
      run: |
        python3 - <<'PY'
        import json, os, sys

        json_file = os.environ["JSON_FILE"]
        output_file = os.environ["SUMMARY_FILE"]
        ...
        PY
```

Port the existing logic verbatim (counters, top-15 table, the scan-counts.json emission using `os.environ.get('IMAGE_NAME','')` / `VERSION` as today, the same error-handling `except` that writes the error card). No behaviour change — only the quoting mechanism.

- [ ] **Step 5: Document scan/test advisory semantics in `ci-dispatch.yml`**

Extend the MERGE_TO_MAIN comment block with one line:
`# SCAN and TEST are advisory by design (report-only) — their results are shown in SUMMARY but never gate the merge.`

- [ ] **Step 6: Lint + commit**

```bash
git add -A && git commit -m "fix(scan): single pinned Trivy pass, heredoc report script; drop unused SARIF path and permission"
```

---

### Task 10: Documentation catch-up

**Files:**
- Rewrite: `.github/workflows/Readme.md`
- Modify: `/home/ubuntu/code/Image/CLAUDE.md` (NOT in this git repo — edit in place, no commit needed for it in this repo)
- Check: `.github/actions/setup-rclone/README.md` — update the step description if it documents per-step ensure_rclone.

**Why:** `Readme.md` documents the deleted `docker-ci.yml` (Docker Hub pushes, "Approve and Deploy", label-based validation) — none of it exists. Root `CLAUDE.md` claims PREPARE "validates exactly 1 Dockerfile changed, checks compilation=auto and arch labels" and that push targets include Docker Hub — all stale.

- [ ] **Step 1: Rewrite `.github/workflows/Readme.md`** to describe the CURRENT pipeline. Required content (write real prose, ~100-150 lines):
  - Trigger: push to `cicd-<main>/<feature>`; concurrency per branch (newest wins).
  - Mermaid diagram of the real job graph: PREPARE → BUILD → {SCAN, TEST, PUSH_PRIV} → PUSH_PUBLIC(approval or devmode) → DEPLOY(shpc) → SUMMARY → MERGE_TO_MAIN | CLEANUP_BRANCH.
  - manifest.json contract: main/feature/version(semver)/platform(x86|arm)/devmode/scan(+legacy noscan)/shpc/targets/private-targets/template/labels.
  - Behaviour table: what fails the run (invalid manifest, build, private/public push), what is advisory (SCAN, TEST), what gets approval (public push, unless devmode), when the branch is merged vs deleted.
  - Artifacts: S3 tar/sif naming, trivy-reports-* + test-results-* + image-manager-summary artifacts and who consumes them (ImageManagerWeb).
  - Companion workflows: cleanup.yml, registry-cleanup.yml, image-sync.yml (one paragraph each).
- [ ] **Step 2: Update root CLAUDE.md** ImageManagerAction section: fix the reusable-prepare description (manifest validation, not "1 Dockerfile changed"/labels), remove Docker Hub from push targets (quay.io pawsey/pawseysc + Setonix registry + S3/SIF), mention MERGE_TO_MAIN/CLEANUP_BRANCH and summary.json.
- [ ] **Step 3: Commit** (Readme + rclone README in ImageManagerAction repo):

```bash
git add -A && git commit -m "docs: rewrite workflow README for the current pipeline; retire docker-ci era docs"
```

---

## Self-Review Notes

- Task ordering resolves file conflicts: Task 1 strips dead code before Tasks 2/3 edit the same files; Task 4's checkouts must land before Task 6 sources `.github/scripts/retry.sh` in push jobs. Execute strictly in order.
- Deliberately NOT changed: MERGE_TO_MAIN ignoring SCAN/TEST results (advisory by design — now documented); devmode approval bypass (documented owner decision); `version` carrying the platform suffix; matrix naming semantics (golden-tested).
- All eight `exit 0` validation sites in PREPARE become failures — this changes run-level status for invalid uploads from green→red, which is the point; ImageManagerWeb polls run status via REST and will now show a real failure instead of a silent green no-op.
