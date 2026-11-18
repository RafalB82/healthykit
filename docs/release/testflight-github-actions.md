# TestFlight upload through GitHub Actions

Use this when local Xcode cannot complete the App Store Connect archive/upload path, or when you want the release to run from a clean hosted macOS 26 runner.

## One-time setup (repository owner or admin)

1. In **Settings → Secrets and variables → Actions**, remove the legacy **repository secrets** `APP_STORE_CONNECT_API_KEY_ID`, `APP_STORE_CONNECT_API_ISSUER_ID`, and `APP_STORE_CONNECT_API_PRIVATE_KEY`. Remove any organization-level copies exposed to this repository and cancel queued or active runs of the old workflow. Older branches and tags can still run older workflow code; changing the workflow on `main` does not protect those revisions. Revoke the old App Store Connect key and issue a replacement if a run on a non-`main` ref could access it.
2. In **Settings → Rules → Rulesets**, create an **Active** branch ruleset targeting exactly `main`. Enable **Require a pull request before merging** with at least one approving review, **Dismiss stale pull request approvals when new commits are pushed**, **Restrict deletions**, and **Block force pushes**. Leave the bypass list empty. This must require review of workflow and release scripts just like any other change to `main`.
3. In **Settings → Environments**, create `testflight-release`. Under **Deployment branches and tags**, choose **Selected branches and tags**, then add one rule of type **Branch**, with the exact name `main`. Do not add a tag rule or any other branch. Under **Deployment protection rules**, enable **Required reviewers**, add a release reviewer who can approve someone else's dispatch, enable **Prevent self-review**, and turn off **Allow administrators to bypass configured protection rules** where that switch is available. Save the rules before adding secrets.
4. Under that environment's **Environment secrets**, add:

   - `TESTFLIGHT_APP_STORE_CONNECT_API_KEY_ID`: the key ID.
   - `TESTFLIGHT_APP_STORE_CONNECT_API_ISSUER_ID`: the issuer ID.
   - `TESTFLIGHT_APP_STORE_CONNECT_API_PRIVATE_KEY`: the full `.p8` private key contents.

   Paste the raw multiline `.p8` contents or use escaped newlines (`\n`). Do not create repository or organization secrets with these names. GitHub's `${{ secrets.* }}` syntax doesn't enforce a secret's scope; keeping these names exclusive to the environment is what makes its protections apply.

GitHub's [environment protection features](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments) depend on plan and repository visibility. For example, Required reviewers (and therefore Prevent self-review) are public-repository only on GitHub Free, Pro, and Team. If the repository cannot enforce the main-only environment and independent approval, leave the environment unprovisioned and use a separately reviewed local release instead. The workflow can detect whether `main` has a protection rule, but cannot tell whether the rule requires review or whether the environment's settings have changed.

## Upload

1. Confirm the App Store Connect app exists for `com.megabyte0x.HealthSync`.
2. Merge the reviewed release commit to protected `main`, then open GitHub Actions and run `TestFlight Upload` using branch `main`.
3. Use `version` `1.0.1` for the maintenance release.
4. Leave `build_number` blank to use the GitHub run number, or enter a positive decimal integer such as `11` for the maintenance candidate. Build 10 was an earlier export-only candidate.
5. Enable `export_only` to prepare a signed IPA artifact without uploading to TestFlight. Leave it disabled for the existing direct upload behavior.
6. Have a different release reviewer verify the run's commit and dispatch inputs, then approve the `testflight-release` deployment. This approval is required for all credential-bearing modes, including status checks and signed exports.

The workflow validates the ref and effective build number on Linux without Apple credentials. After approval, the archive/upload job on `macos-26` verifies the runner has an iOS 26 SDK and runs the complete iOS XCTest suite before writing the signing key. It then archives `HealthSync` using automatic signing for team `9UR77TD484`. With `export_only` enabled it exports a signed IPA into the `testflight-diagnostics` artifact. Otherwise it uploads directly to App Store Connect/TestFlight. Test results and distribution diagnostics are included in the artifact.

## Prepare the maintenance candidate

Run the workflow from `main` after merging the reviewed maintenance changes:

```bash
gh workflow run testflight.yml --repo megabyte0x/healthysync \
  --ref main \
  -f version=1.0.1 -f build_number=11 -f export_only=true
```

Download the `testflight-diagnostics` artifact from the successful run. Its `HealthSync-export` folder contains the signed IPA. Keep the artifact private when distributing it for review. For a later TestFlight upload of that candidate, confirm `main` still points to the validated commit and set `export_only=false`.

## Check processing without another upload

Enable `status_only` to read recent App Store versions and build processing states using the approved environment credentials. This mode skips the macOS build/upload job and makes only read requests to Apple's API. It also works after an upload performed locally with an existing signing identity:

```bash
gh workflow run testflight.yml --repo megabyte0x/healthysync \
  --ref main -f version=1.0.3 -f status_only=true
```

An uploaded or processed build is not a public release. Verify its processing result, select it for the intended App Store version, complete App Review and release it before expecting public users to receive the update.

## Release the verified URL migration

The migration-specific workflow modes are restricted to app `6776575569`, version `1.0.3`, and processed build `35`. `prepare_store_version=true` prepares the App Store draft and English release notes without submitting. `submit_store_version=true` verifies the selected build, existing review information, release notes and all six inherited iPhone screenshots, then submits only that version for review. It retains the existing `AFTER_APPROVAL` release policy. Supply only one of the status, prepare or submit flags; conflicting flags skip all release jobs. These fixed candidate identifiers must be reviewed before reusing the scripts for another release.

```bash
gh workflow run testflight.yml --repo megabyte0x/healthysync \
  --ref main -f version=1.0.3 -f prepare_store_version=true
gh workflow run testflight.yml --repo megabyte0x/healthysync \
  --ref main -f version=1.0.3 -f submit_store_version=true
```

Confirm preparation and review readiness before running the second command. Keep the legacy Supabase bridge available during App Review and client rollout, as described in [the retirement runbook](../operations/supabase-retirement.md).
