# dependamachine

Shared CI/CD automation for iOS and Android SDK projects.

## Structure

```
dependamachine/
├── ios/                            # iOS-specific automation
│   ├── scripts/                    # Reusable Ruby/Shell scripts
│   │   ├── pods_updater.rb         # CocoaPods dependency updater
│   │   ├── collect_adapter_errors_report.rb  # Xcode error parser
│   │   └── scan_deprecations.sh    # Deprecated API scanner
│   ├── workflows/                  # Reusable GitHub Actions workflows
│   │   ├── pods-updater.yml        # Scheduled pod update workflow
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
