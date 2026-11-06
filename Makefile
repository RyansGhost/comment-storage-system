# Convenience targets. Assumes SBCL + Quicklisp (loaded from ~/.sbclrc).
LISP ?= sbcl
REGISTER = --eval '(push (uiop:getcwd) asdf:*central-registry*)'

.PHONY: test run build docker docker-test up logs backup

test:          ## run the FiveAM suite
	$(LISP) --non-interactive $(REGISTER) \
	  --eval '(ql:quickload :rf-comments/tests :silent t)' \
	  --eval '(asdf:test-system :rf-comments)'

run:           ## dev server on :8080 (admin password "admin", emails printed)
	$(LISP) --load dev/start.lisp

build:         ## standalone executable in bin/rf-comments
	$(LISP) --non-interactive --load build.lisp

docker:        ## runtime image
	docker build -t rf-comments:latest .

docker-test:   ## run the test-suite inside Docker
	docker build --target test -t rf-comments:test .

up:            ## build and start with docker compose
	docker compose up -d --build

logs:
	docker compose logs -f comments

backup:        ## consistent online backup of the live database
	sqlite3 data/comments.db ".backup 'data/backup-$(shell date +%Y%m%d-%H%M%S).db'"
