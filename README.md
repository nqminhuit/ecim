# ECIM — Emacs CI Manager

## Goal

ECIM is an Emacs-native interface for managing CI/CD workflows from within Emacs.

The first implementation should focus on **GitHub Actions**, allowing users to:

* View workflows
* View workflow runs
* View run status, conclusion, branch, commit, event, actor, and timing
* View jobs and their individual statuses
* View job logs
* View and download workflow artifacts
* Trigger workflows manually
* Provide inputs when triggering `workflow_dispatch`
* Cancel running workflows
* Rerun workflows/jobs where supported
* Open the corresponding workflow/run in the browser

The UI should feel native to Emacs rather than simply wrapping the GitHub web interface.

## Repository and Account Detection

ECIM should determine the current repository from the current working directory / Git repository.

It should also determine which GitHub account/identity should be used for that repository.

This is important because users may have multiple GitHub accounts, such as personal and work accounts.

The account/authentication design should be **repository-aware**, rather than relying on one globally active GitHub account.

Do not assume that Git SSH authentication and GitHub API authentication are the same thing. Treat Git remote detection and API authentication as separate concerns.

Authentication should be designed so that it can support multiple accounts cleanly, preferably using Emacs facilities such as `auth-source` and/or repository-local configuration.

## Architecture

Although GitHub Actions is the only supported provider initially, the package should have a provider abstraction from the beginning.

The architecture should roughly separate:

1. Core/provider-independent functionality
2. CI/CD provider interface
3. GitHub Actions provider
4. Authentication
5. Repository detection
6. UI
7. Async network/API operations
8. Artifact/log handling

For example:

```text
ecim/
├── ecim.el
├── ecim-core.el
├── ecim-provider.el
├── ecim-github.el
├── ecim-auth.el
├── ecim-repository.el
├── ecim-ui.el
├── ecim-runs.el
├── ecim-logs.el
└── ecim-artifacts.el
```

This structure is only a suggestion. Adjust it if there is a better Emacs architecture.

The provider interface should eventually make it possible to add providers such as:

* GitLab CI
* Forgejo Actions
* Gitea Actions
* Other CI/CD systems

However, **do not implement those providers yet**. GitHub Actions is the only target for the first version.

## Emacs Integration

The package should integrate naturally with existing Emacs workflows.

In particular:

* Detect the repository from the current directory
* Prefer asynchronous operations so Emacs does not block during network requests
* Use standard Emacs libraries where appropriate
* Use `tabulated-list-mode` or another suitable built-in UI for lists
* Support `completing-read` / `read-string` where appropriate
* Make buffers easy to refresh
* Provide sensible keybindings
* Keep the UI keyboard-friendly
* Avoid unnecessary dependencies

## GitHub API

Use the GitHub Actions API rather than scraping GitHub's web UI.

The GitHub implementation should encapsulate API details so that the rest of ECIM does not depend directly on GitHub-specific concepts.

The API layer should provide functions conceptually similar to:

```elisp
(ecim-provider-list-workflows)
(ecim-provider-list-runs)
(ecim-provider-get-run)
(ecim-provider-list-jobs)
(ecim-provider-get-job-log)
(ecim-provider-list-artifacts)
(ecim-provider-download-artifact)
(ecim-provider-trigger-workflow)
(ecim-provider-cancel-run)
(ecim-provider-rerun-run)
```

Use idiomatic Emacs Lisp naming and APIs rather than necessarily copying these exact function names.

## Initial UI

The first usable interface should provide a workflow/run dashboard similar to:

```text
ECIM: repository-name

Workflow Runs
──────────────────────────────────────────────
✓ CI             #1842   main        2m ago
✗ CI             #1841   main       18m ago
✓ Release        #317    v2.4.1      1h ago
⟳ Docker Build   #892    feature/x   running

Commands:
RET  View run
r    Refresh
l    Logs
a    Artifacts
R    Run workflow
c    Cancel
g    Open in GitHub
```

The exact UI is flexible. Prioritize usability and extensibility over reproducing GitHub's interface.

## Workflow Triggering

When a workflow supports `workflow_dispatch`, ECIM should allow the user to trigger it from Emacs.

The UI should:

1. Let the user select a workflow
2. Let the user select the ref/branch/tag
3. Detect the workflow's dispatch inputs
4. Prompt for required/optional inputs
5. Trigger the workflow
6. Show the resulting run when possible

## Design Principles

Keep the implementation:

* Modular
* Extensible
* Idiomatic Emacs Lisp
* Asynchronous where appropriate
* Easy to test
* Easy to configure
* Minimal in dependencies
* Independent of GitHub's web UI

Do not over-engineer the provider abstraction. It should be sufficient to support future providers without making the GitHub implementation unnecessarily complicated.

Start with a clean project structure and a minimal working implementation. Explain important architectural decisions and keep provider-specific code isolated. Keep explanation brief and concise and easy to understand, use common vocabulary. Do not add unnecessary code comments if the function is self-explanatory. Avoid over-engineering the provider abstraction. The GitHub implementation should be simple and idiomatic, while still being extensible for future providers.

## First Milestone

The first milestone should be a working GitHub Actions implementation that can:

1. Detect the current Git repository
2. Authenticate to GitHub
3. List workflows
4. List workflow runs
5. View run details
6. View jobs
7. View job logs
8. List/download artifacts
9. Trigger a workflow
10. Refresh/poll run status
