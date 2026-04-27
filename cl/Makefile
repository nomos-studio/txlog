# txlog/cl — Common Lisp peer build
#
# Targets:
#   make test    — load txlog and run the fiveam suite, exits non-zero on failure
#   make load    — quickload :txlog and exit (smoke test)
#   make repl    — interactive REPL with :txlog loaded
#   make clean   — remove FASL caches under ~/.cache/common-lisp/

LISP ?= sbcl
SBCL_FLAGS = --non-interactive --no-sysinit

.PHONY: test load repl clean

test:
	$(LISP) $(SBCL_FLAGS) \
	  --eval '(ql:quickload :txlog/test :silent t)' \
	  --eval '(asdf:test-system :txlog)'

load:
	$(LISP) $(SBCL_FLAGS) \
	  --eval '(ql:quickload :txlog :silent t)' \
	  --eval '(format t "~&txlog loaded.~%")'

repl:
	$(LISP) --eval '(ql:quickload :txlog)'

clean:
	rm -rf ~/.cache/common-lisp/*/$(CURDIR)
