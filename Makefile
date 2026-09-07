EMACS ?= emacs
BATCH  = $(EMACS) -Q --batch -L . -L test
SOURCES = ecim-core.el ecim-repository.el ecim-auth.el ecim-provider.el \
          ecim-github.el ecim-ui.el ecim-logs.el ecim-artifacts.el \
          ecim-runs.el ecim.el

.PHONY: all compile test lint clean

all: compile test

# Byte-compilation is the lint that matters for Emacs Lisp: it is the
# only thing that reports undefined functions and unused bindings.
compile: clean
	$(BATCH) -f batch-byte-compile $(SOURCES)

test:
	$(BATCH) -l ert -l test/ecim-tests.el -f ert-run-tests-batch-and-exit

lint:
	$(BATCH) --eval '(progn (require (quote checkdoc)) (dolist (f (list $(patsubst %,"%",$(SOURCES)))) (checkdoc-file f)))'

clean:
	rm -f *.elc test/*.elc
