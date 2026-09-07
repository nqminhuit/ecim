EMACS ?= emacs
BATCH  = $(EMACS) -Q --batch -L . -L test
SOURCES = ecim-core.el ecim-repository.el ecim-auth.el ecim-provider.el \
          ecim-github.el ecim-ui.el ecim-logs.el ecim-artifacts.el \
          ecim-runs.el ecim.el

.PHONY: all compile compile-strict test lint clean

all: compile test

# Byte-compilation is the lint that matters for Emacs Lisp: it is the
# only thing that reports undefined functions and unused bindings.
compile: clean
	$(BATCH) -f batch-byte-compile $(SOURCES)

# The same, but a warning fails the build.  Used by CI on one Emacs
# version; older versions warn about different things, which would make
# the matrix red for reasons that are not defects.
compile-strict: clean
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile $(SOURCES)

test:
	$(BATCH) -l ert -l test/ecim-tests.el -f ert-run-tests-batch-and-exit

# checkdoc reports through the warning log and still exits 0, so treat
# any output as a failure or the check is decorative.
lint:
	@output=$$($(BATCH) --eval '(progn (require (quote checkdoc)) (dolist (f (list $(patsubst %,"%",$(SOURCES)))) (checkdoc-file f)))' 2>&1); \
	if [ -n "$$output" ]; then printf '%s\n' "$$output"; exit 1; fi; \
	echo "checkdoc: clean"

clean:
	rm -f *.elc test/*.elc
