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

## Requirements

ECIM needs Emacs 27.1 or later and nothing else: no external packages, and no command line tools.

Two conditions must hold, and ECIM reports each as an authentication error rather than failing
obscurely in the middle of a request:

* **The repository must be cloned over HTTPS**, with a token in the remote URL
  (`https://<token>@github.com/owner/repo.git`, or `https://<user>:<token>@…`). An SSH remote
  carries no API credential, so an SSH clone works only if a token is supplied through `auth-source`
  instead.
* **The token must be allowed to read Actions** — the `workflow` scope on a classic token, or the
  Actions permission on a fine-grained one. A token created only for pushing will authenticate
  successfully and then be refused by every Actions endpoint; ECIM reports that as a missing
  permission rather than a bare "Forbidden".

## Usage

```elisp
(add-to-list 'load-path "/path/to/ecim")
(require 'ecim)
```

`M-x ecim` inside a repository opens the run dashboard:

```text
RET  jobs of the run          l  job log
a    artifacts                R  run a workflow
c    cancel                   G  rerun (C-u: failed jobs only)
W    workflows                /  filter by branch
g    refresh                  w  open in a browser
```

Useful settings: `ecim-auto-refresh-interval` (off by default; when set, a buffer refreshes itself
only while something in it is still running), `ecim-artifact-directory`, `ecim-runs-limit`,
`ecim-logs-strip-timestamps`.

## Repository and Account Detection

ECIM determines the current repository from the current working directory / Git repository.

It also determines which GitHub account/identity is used for that repository.

This matters because users may have multiple GitHub accounts, such as personal and work accounts.

The authentication design is **repository-aware** rather than relying on one globally active GitHub
account, and it achieves that through the repository itself: the token in a clone's own remote URL
belongs to that clone, so a personal checkout and a work checkout carry different credentials with
no further configuration.

Repository detection and credential reading are nevertheless separate steps. Detection parses the
remote for host, owner and name only, and discards any credential in it, because the result is
cached, passed around and displayed. The token is read separately, on demand, and never stored in
those structures.

The lookup order is:

1. `auth-source` for the login configured for the repository — `ecim.account` in the Git config, or
   the `ecim-account` directory-local variable. Naming a login is an explicit choice, so it wins.
2. The token embedded in the HTTPS remote URL.
3. `auth-source` for the API host, then the web host.

`auth-source` is therefore optional, and exists so that a token need not be kept in plain text in
`.git/config`; an entry looks like:

```text
machine api.github.com login <your-login> password <your-token>
```

`M-x ecim-auth-forget` discards cached credentials so they are looked up again.

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

The first milestone is a working GitHub Actions implementation that can:

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

All ten are implemented.

## Development

```sh
make compile   # byte-compile; warnings are the lint that matters for Emacs Lisp
make test      # ERT suite, no network access
make lint      # checkdoc
make           # compile + test

# A single test, or a regexp selecting several
emacs -Q --batch -L . -L test -l ert -l test/ecim-tests.el \
  --eval '(ert-run-tests-batch-and-exit "parse-remote")'
```

The tests never touch the network: stub `ecim-github--fetch` rather than adding a test that needs
credentials.
