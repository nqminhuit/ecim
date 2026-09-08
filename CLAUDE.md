# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What ECIM is

ECIM (Emacs CI Manager) is an Emacs-native interface for managing CI/CD from inside Emacs. The first
and *only* provider is **GitHub Actions**, driven through the GitHub Actions REST API — never by
scraping the web UI. Other providers (GitLab CI, Forgejo, Gitea) must stay possible but must not be
implemented. `README.md` is the specification and stays authoritative when it and this file disagree.

The first milestone is implemented: repository detection, per-repository auth, workflows, runs, jobs,
job logs, artifacts (list and download), manual dispatch, and refresh/polling.

## Commands

Emacs 31.1 at `/usr/bin/emacs`. No third-party dependencies — everything is built-in.

```sh
make compile        # batch byte-compile; the real lint for Elisp, keep it warning-free
make compile-strict # the same with `byte-compile-error-on-warn'; what CI enforces
make test           # ERT suite (test/ecim-tests.el), no network
make lint           # checkdoc; exits non-zero on any finding, currently clean
make                # compile + test

# One test, or a regexp selecting several
emacs -Q --batch -L . -L test -l ert -l test/ecim-tests.el \
  --eval '(ert-run-tests-batch-and-exit "parse-remote")'

# Try it against a live repository
emacs -Q -L . -l ecim.el   # then M-x ecim inside a GitHub clone
```

CI (`.github/workflows/ci.yml`) runs compile + test over Emacs 29.4/30.2/31.1/snapshot and enforces
`compile-strict` + `lint` on 31.1 only — older byte-compilers warn about different things, so a
strict matrix would go red for reasons that are not defects. The workflow also takes
`workflow_dispatch` inputs (a `choice` and a `boolean`), which doubles as live test data for
ECIM's own dispatch-input parser.

Byte-compile before declaring work done: undefined functions, wrong arity and unused lexicals show up
there and nowhere else. The tests never touch the network — stub `ecim-github--fetch` (see
`ecim-tests--capturing`) rather than adding tests that require credentials.

## Architecture

Layered, one concern per file. The rule that keeps it honest: **GitHub vocabulary lives only in
`ecim-github.el`.** Everything above it speaks in core structs.

- `ecim.el` — entry points, autoloads, package headers.
- `ecim-core.el` — structs (`ecim-repo`, `ecim-workflow`, `ecim-run`, `ecim-job`, `ecim-artifact`,
  `ecim-input`), faces, time and status formatting, error conditions.
- `ecim-provider.el` — the seam: `cl-defgeneric` dispatching on a provider symbol via
  `(eql github)` methods. No registry, no struct of lambdas. Adding a provider means adding methods.
- `ecim-github.el` — HTTP transport, endpoints, JSON→struct conversion, dispatch-input parsing.
- `ecim-auth.el` — repository-aware token resolution.
- `ecim-repository.el` — Git remote parsing and repo detection.
- `ecim-ui.el` — `ecim-list-mode`, the parent of every listing.
- `ecim-runs.el` / `ecim-logs.el` / `ecim-artifacts.el` — the views.

Provider operations are all asynchronous and take `(provider repo ... callback &optional errback)`.
Callbacks receive core structs; `errback` defaults to `ecim--report-error`.

### Things that are easy to get wrong

These cost time to rediscover, and several were found only by running against the real API:

- **Log and artifact endpoints answer 302** with a signed storage URL that rejects an `Authorization`
  header. Those requests set `url-max-redirections` to 0 and refetch the target unauthenticated
  (`ecim-github--redirect-target`). Emacs 31 happens to strip the header itself, older versions do not.
- **`:redirect` in a url.el status plist does not mean "you must redirect".** url.el adds it to record
  a redirect it *already followed*, and the response delivered alongside it is the final, successful
  one (`url-http.el:772-775`). Only the refused redirect — `(:error (error http-redirect-limit URL))`
  — is ECIM's to follow. Treating `:redirect` as actionable throws away good replies and refetches
  them without credentials, turning working calls into 401s.
- **The token cache key must include the repository root.** With no `ecim.account` configured the
  credential comes from each clone's own remote URL, so a host-wide key would serve the first
  repository's token to every other repository on that host — silently defeating the whole
  per-repository design.
- **url.el reports every 4xx/5xx as `(error http CODE)`**, which renders as "peculiar error: 404".
  `ecim-github--handle` therefore prefers its own message whenever a status code is available and
  falls back to url.el's object only for transport failures.
- **Listings are wrapped in an envelope** (`{"workflow_runs": [...]}`), so pagination must merge the
  inner list — appending whole bodies silently keeps only page one. That is what `:collect` is for.
- **`tabulated-list-mode` owns `header-line-format`** for its sortable column names. ECIM's own status
  goes in `mode-line-process` via `ecim--update-status`.
- **List columns widen to fit their data** (`ecim--size-columns`, wired into `ecim--fill` through the
  buffer-local `ecim--column-caps`), rather than always truncating to a fixed width. A column with a
  cap can still hold a cell wider than it: `tabulated-list-print-col` elides the overflow through a
  `display` text property reading `"…"`, not by shortening the string, so `buffer-string` and
  `substring-no-properties` show the untruncated text — check `get-text-property` for `display` at the
  cutoff instead of dumping the buffer, or the truncation looks like it silently isn't happening.
- **A manual `{`/`}` resize must survive the next refresh.** `ecim--size-columns` recomputes every
  column from the mode's original format on each fill, which would otherwise silently undo whatever
  the user just resized by hand. The bookkeeping (`ecim--user-sized-columns`) is attached as advice
  on `tabulated-list-widen-current-column` itself (`ecim--note-manual-column-resize`), not just bound
  in `ecim-list-mode-map`: a modal-editing package's own keymap for `tabulated-list-mode` (e.g. Evil
  via `evil-collection`) is checked before any major mode's own map and can call the built-in
  directly, bypassing a key binding entirely. `ecim-widen-column`/`ecim-narrow-column` still exist as
  named aliases so the map shows something recognizably ECIM's, but the advice is what actually makes
  the resize stick, regardless of which keymap reached the built-in.
- **`map-keymap` walks the entire `keymap-parent` chain**, all the way to `global-map` — it is not a
  "this mode's own bindings" primitive. `ecim--keymap-own-bindings` (`ecim-core.el`) gets that by
  temporarily detaching the parent with `set-keymap-parent`, walking, then restoring it in an
  `unwind-protect`; both `ecim-evil.el`'s mirroring and `ecim-show-keybindings`'s cheat sheet build on
  it. Skipping this step once mirrored/showed the same ~40 inherited bindings (`digit-argument`,
  `mouse-select-window`, ...) once per ancestor mode's hook, duplicated across the hook chain.
- **`with-help-window`'s body runs with `current-buffer` switched to the help buffer**, not the buffer
  that invoked it (confirmed in `help.el`'s `help--window-setup`: the callback sits inside a
  `with-current-buffer` on the new buffer). `ecim-show-keybindings` computes `current-local-map` and
  `mode-name` *before* entering `with-help-window`, or it would describe `*ecim-keys*` itself.
- **Evil (and `evil-collection`) install a keymap for a mode, or an ancestor of it, that is checked
  before any major mode's own map** — a plain key binding cannot reach past it. `ecim-evil.el`
  reapplies each of ECIM's own bindings as a local Evil key from a hook on the *most-derived* mode's
  own hook variable, not a one-time `evil-define-key`: `run-mode-hooks` always fires an ancestor's
  hook before the child's own, so this is guaranteed to run last regardless of whether a given
  evil-collection module's own setup is one-time-global or reasserted per buffer. The whole file sits
  behind `with-eval-after-load 'evil`, so it costs nothing when Evil is absent, and
  `(declare-function evil-local-set-key "evil")` keeps `compile-strict` from erroring on a reference
  to a function ECIM never depends on.
- **checkdoc's defaults are version-dependent.** `checkdoc-verb-check-experimental-flag` is on before
  Emacs 31 and off from 31, and it scans the whole docstring for words like "runs" and "returns",
  reading every such noun as a verb in the wrong mood. `make lint` pins it off so local and CI agree;
  do not reword correct documentation to satisfy it.
- **Job logs start with a UTF-8 BOM**, which hides the first line's timestamp from the stripper.
- **The Actions API does not expose `workflow_dispatch` inputs.** They are read from the workflow file
  through the contents API and parsed by the small indentation-based reader in `ecim-github.el`. When
  it returns nil the caller falls back to free-form `name=value` prompts (`C-u M-x ecim-run-workflow`).
- **The entry points autoload the views, not the package.** `M-x ecim` loads `ecim-runs.el`, which
  requires the provider *interface* and no implementation — only `ecim.el` requires them all, and the
  autoload path never goes through it. `ecim-provider-for-repo` therefore `require`s the provider it
  selects; without that the generics dispatch with no applicable method. Anything testing this has to
  run in a fresh Emacs, since the test suite loads `ecim-github` itself and hides the problem.
- **Do not prompt from inside a url.el callback** — that runs in a process filter. Defer with
  `ecim--later`.
- **A refresh must not re-display its buffer**, or auto-refresh steals the window. Each view splits
  `ecim-show-X` (display) from `ecim-X--load` (fetch).

### Authentication

**ECIM is HTTPS-only and needs a token that may read Actions.** Both are stated up front and raised
as `ecim-auth-error` rather than being discovered halfway through a request. There is no dependency
on the `gh` CLI.

Resolution order in `ecim-auth-token`:

1. `auth-source` for the login configured for the repo (`git config ecim.account`, or the
   `ecim-account` directory-local variable) — naming a login is an explicit choice, so it wins.
2. The token embedded in the HTTPS remote URL (`ecim-auth--from-remote-url`), which is what makes
   auth repository-local by construction.
3. `auth-source` for the API host, then the web host.

Consequences to keep in mind when changing this:

- An SSH clone carries no token and only works with an `auth-source` entry.
- A token minted for pushing authenticates and is then refused by every Actions endpoint, so
  `ecim-github--error` reports a 403 by naming the missing permission, reading
  `x-accepted-github-permissions` and `x-oauth-scopes` off the response.
- The secret is read on demand from `.git/config` and deliberately **not** stored in the `ecim-repo`
  struct, which is cached, passed everywhere and printed. `ecim-repository--parse-remote` strips
  userinfo for that reason, with a regression test asserting the token cannot ride along.

## Conventions

- `ecim-` public, `ecim--` internal, lexical binding everywhere.
- Prefer built-ins: `url.el`, `json-parse-string`/`json-serialize`, `auth-source`, `tabulated-list-mode`.
- Comments only where the code is not self-explanatory; the README asks for restraint.
