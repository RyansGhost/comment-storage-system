;;;; rf-comments.asd — a tiny multi-site comment service.
;;;;
;;;; ----------------------------------------------------------------------
;;;; READING GUIDE: what an .asd file is
;;;; ----------------------------------------------------------------------
;;;; Common Lisp has no built-in notion of a "project". ASDF (Another System
;;;; Definition Facility, bundled with every modern implementation) fills
;;;; that gap: a *system* names a set of source files, the order to compile
;;;; them in, and the other systems it depends on. It's roughly a
;;;; package.json or Cargo.toml plus a build tool.
;;;;
;;;; Quicklisp sits on top of ASDF and adds downloading:
;;;; (ql:quickload "rf-comments") fetches every system in :depends-on that
;;;; isn't installed yet, then calls (asdf:load-system "rf-comments"), which
;;;; compiles each file to a .fasl (cached under ~/.cache/common-lisp/) and
;;;; loads it into the running image.
;;;;
;;;; This file is read by ASDF, not loaded like normal source, so keep it
;;;; declarative. The two systems below are:
;;;;
;;;;   rf-comments         the service itself
;;;;   rf-comments/tests   the FiveAM test-suite ("/" names a secondary
;;;;                       system that ASDF looks for in this same file)
;;;;
;;;; Suggested reading order for the source is the :components order below.
;;;; Each file only uses things defined in the files before it.

(asdf:defsystem "rf-comments"
  :description "Tiny self-hosted comment service for ryanfleck.ca subdomains."
  :author "Ryan Fleck <dev@ryanfleck.ca>"
  :version "0.1.0"
  ;; Every library we use. Quicklisp resolves these names to downloads.
  ;; What each one is for:
  ;;   hunchentoot      the HTTP server (Edi Weitz). Threaded, mature, the
  ;;                    de-facto standard CL web server.
  ;;   easy-routes      a routing layer for Hunchentoot: URL templates like
  ;;                    "/admin/sites/:id" plus "decorators" (middleware).
  ;;   sqlite           cl-sqlite, a thin CFFI binding to libsqlite3.
  ;;   spinneret        HTML generation from s-expressions, escaping by default.
  ;;   com.inuoe.jzon   JSON parse/serialise (fast, strict, well maintained).
  ;;   ironclad         cryptography: SHA-256, HMAC, secure random bytes.
  ;;   dexador          HTTP *client* (to call Amazon SES and Gravatar).
  ;;   cl-ppcre         Perl-compatible regular expressions.
  ;;   quri             URL parsing and percent-encoding.
  ;;   bordeaux-threads portable threads and locks (Hunchentoot runs one
  ;;                    thread per connection, so shared state needs locks).
  ;;   babel            string <-> UTF-8 octet conversion.
  ;;   alexandria       the "standard library extension" everyone uses.
  ;;   flexi-streams    Hunchentoot's stream layer; we name its UTF-8 format.
  ;;   sb-posix         SBCL's POSIX bindings (chmod/setenv in repl.lisp).
  ;;   uiop             ASDF's portability utilities (getenv, files, quitting).
  :depends-on ("hunchentoot"
               "easy-routes"
               "sqlite"
               "spinneret"
               "com.inuoe.jzon"
               "ironclad"
               "dexador"
               "cl-ppcre"
               "quri"
               "bordeaux-threads"
               "babel"
               "alexandria"
               "flexi-streams"
               "sb-posix"
               "uiop")
  ;; :SERIAL T means "each component depends on the one before it": files
  ;; compile and load strictly top to bottom. That's the simplest correct
  ;; choice for a small project, where macros defined in one file (e.g.
  ;; routes.lisp) must exist before files that use them (web.lisp) are
  ;; *compiled*, not just run.
  :serial t
  :components ((:module "src"
                :components ((:file "package")  ; the namespace
                             (:file "config")   ; settings (env vars)
                             (:file "util")     ; time, crypto, URLs, validation
                             (:file "db")       ; SQLite + data model
                             (:file "email")    ; SES client + SigV4 signing
                             (:file "events")   ; CLOS observers on comments
                             (:file "avatars")  ; Gravatar proxy
                             (:file "views")    ; HTML layout + CSS
                             (:file "routes")   ; request plumbing + route macros
                             (:file "web")      ; public pages and APIs
                             (:file "admin")    ; admin GUI
                             (:file "repl")     ; opt-in live REPL
                             (:file "main")))   ; start/stop/executable entry
               ;; Static files are listed so ASDF knows they belong to the
               ;; system (and ships them), but they aren't compiled. web.lisp
               ;; reads them into memory at load time.
               (:module "static"
                :components ((:static-file "embed.js")
                             (:static-file "thread.js")
                             (:static-file "count.js"))))
  ;; (asdf:test-system "rf-comments") should run the tests, but the tests
  ;; live in another system. This line says "testing me means testing
  ;; rf-comments/tests".
  :in-order-to ((test-op (test-op "rf-comments/tests"))))

(asdf:defsystem "rf-comments/tests"
  :description "FiveAM test-suite for rf-comments."
  ;; fiveam: the test framework. dexador + cl-cookie: an HTTP client with a
  ;; cookie jar, to drive the real server like a browser. slynk: so the
  ;; live-REPL feature can be tested end to end.
  :depends-on ("rf-comments" "fiveam" "dexador" "cl-cookie" "slynk")
  :serial t
  :components ((:module "tests"
                :components ((:file "package")
                             (:file "unit")
                             (:file "sigv4")
                             (:file "integration"))))
  ;; How to "perform" the test operation. We can't write
  ;; (fiveam:run! 'rf-comments/tests:all) directly: when ASDF *reads* this
  ;; file, neither the FIVEAM nor the RF-COMMENTS/TESTS package exists yet,
  ;; so the reader would fail on those package-qualified symbols.
  ;; SYMBOL-CALL and FIND-SYMBOL* (from UIOP, available inside .asd files)
  ;; look the symbols up at run time instead. Signalling an error on failure
  ;; makes `sbcl --non-interactive` exit non-zero, which is what `make test`
  ;; and CI rely on.
  :perform (test-op (o c)
             (unless (symbol-call :fiveam :run!
                                  (find-symbol* :all :rf-comments/tests))
               (error "rf-comments tests failed"))))
