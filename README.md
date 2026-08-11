# dependamachine

Shared CI/CD automation for iOS and Android SDK projects.

## Structure

```
dependamachine/
├── ios/                            # iOS-specific automation
│   ├── scripts/                    # Reusable Ruby/Shell scripts
│   │   ├── pods_updater.rb         # CocoaPods dependency updater
│   │   ├── spm_updater.rb          # SPM dependency updater with version gatekeeper
│   │   ├── collect_adapter_errors_report.rb  # Xcode error parser
│   │   └── scan_deprecations.sh    # Deprecated API scanner
│   ├── workflows/                  # Reusable GitHub Actions workflows
│   │   ├── pods-updater.yml        # Scheduled pod update workflow
│   │   ├── spm-updater.yml         # Scheduled SPM update workflow (gated cascade)
│   │   ├── ci-adapter-quality.yml  # Build/test/deprecated check
│   │   ├── automation-post-pods-update.yml  # Auto-fix orchestrator
│   │   └── claude-code.yml         # Claude Code PR comment handler
│   └── claude-prompts/             # Claude AI prompt templates
│       ├── fix-build.md
│       ├── fix-deprecated.md
│       ├── fix-tests.md
│       └── update-changelog.md
├── android/                        # Android-specific automation (TBD)
└── .github/                        # Repo-level CI
```

## Usage

### For iOS projects (bidon-sdk-ios, AppodealSDK-iOS)

Each consuming project needs:

1. **Config file** `.github/pods-updater-config.json` with project-specific parameters
2. **Thin wrapper workflows** in `.github/workflows/` that call reusable workflows from this repo
3. **Release notes URLs** in `.github/release-notes-urls.json`

### Reusable Workflows

Workflows are called via `workflow_call`:

```yaml
# In your project's .github/workflows/pods-updater.yml
jobs:
  update:
    uses: bidon-io/dependamachine/.github/workflows/ios-pods-updater.yml@main
    with:
      config_path: .github/pods-updater-config.json
    secrets: inherit
```

### Config File

Each project maintains `.github/pods-updater-config.json`:

```json
{
  "workspace": "BidOn.xcworkspace",
  "adapter_prefix": "BidonAdapter",
  "adapters_dir": "Adapters",
  "adapters_test_scheme": "AdaptersTests",
  "base_branch": "develop",
  "branch_prefix": "chore/pod-",
  "pod_to_adapter": {
    "AppLovinSDK": ["BidonAdapterAppLovin"]
  },
  ...
}
```

### SPM updater (gated cascade)

`ios/scripts/spm_updater.rb` updates SPM dependency pins the way
`pods_updater.rb` updates CocoaPods pins, with one addition: a
**version-coherence gatekeeper**. SwiftPM resolves a single graph per
workspace and network SDKs are pinned exactly, so one SDK version must be
shared by every consumer (the project adapter, MAX mediation, LevelPlay
mediation, Bidon adapter pods). The cascade per network:

1. **MAX gate (primary)** — a new SDK version is only taken when AppLovin has
   published a mediation adapter for it. No MAX adapter → no bump.
2. **Own pin bump** — the `exactVersion` in the Xcode project, a local
   override package manifest (binaryTarget url/checksum sync), the
   `pin_overrides` literal in adapters.yml and any lockstep pods.
3. **LevelPlay gate (secondary)** — bump the mediation adapter pin if
   IronSource published a tag pinning the new SDK version; otherwise remove
   the package from the build and record it in the deferred store
   (`.github/spm-deferred.json`).
4. **Bidon gate (secondary)** — bump the BidonAdapter pod or comment it out
   and defer.
5. **Restore pass** — a separate branch/PR restores deferred dependencies
   whose stack caught up. Entries marked `"restore": "manual"` (structural
   removals) are never auto-restored.

Consuming projects add `.github/spm-updater-config.json` (see the schema in
the script header) and a thin wrapper workflow calling
`bidon-io/dependamachine/.github/workflows/ios-spm-updater.yml@main`.
