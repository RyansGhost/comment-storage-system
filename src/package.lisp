;;;; package.lisp — the RF-COMMENTS namespace.
;;;;
;;;; A Common Lisp *package* is a namespace for symbols. Every function,
;;;; variable and class name in this project is a symbol interned in the
;;;; RF-COMMENTS package. Each source file begins with (in-package
;;;; #:rf-comments) so the reader interns its symbols here.
;;;;
;;;; Notation: #:foo is an *uninterned* symbol. Using it in DEFPACKAGE
;;;; avoids interning junk symbols named FOO into whatever package happens
;;;; to be current when this file is read. Only the name matters to
;;;; DEFPACKAGE.

(defpackage #:rf-comments
  ;; :USE imports every exported symbol of a package. We only :USE the
  ;; COMMON-LISP package itself.
  (:use #:cl)
  ;; Libraries are referred to through short *local nicknames* instead of
  ;; :USE, for two reasons:
  ;;  1. Clashes: Hunchentoot exports START, STOP, REDIRECT and others, which
  ;;     would collide with our own START/STOP (and :USE-ing two packages
  ;;     that export the same name is an error).
  ;;  2. Readability: when you see ht:header-out you know it's Hunchentoot;
  ;;     jzon:parse is the JSON library; bt:make-lock is bordeaux-threads.
  ;; Local nicknames are visible only inside this package, so they can't
  ;; conflict with other code loaded into the same image. All modern
  ;; implementations support them.
  ;; Other libraries (spinneret, sqlite, ironclad, dexador as `dex`, quri,
  ;; cl-ppcre, easy-routes, uiop…) are used with their full package names
  ;; or their own global nicknames.
  (:local-nicknames (#:ht #:hunchentoot)
                    (#:jzon #:com.inuoe.jzon)
                    (#:bt #:bordeaux-threads))
  ;; Exported symbols are the "public API": what the tests, the REPL and
  ;; build.lisp may use as rf-comments:foo. Internal symbols are still
  ;; reachable as rf-comments::foo (two colons). The tests do that freely;
  ;; the double colon is a visible "I know this is internal" marker.
  (:export
   ;; lifecycle
   #:start #:stop #:main #:load-config #:*acceptor*
   ;; config
   #:*public-url* #:*port* #:*db-path* #:*admin-password* #:*email-backend*
   #:*ses-from* #:*aws-region* #:*aws-access-key-id* #:*aws-secret-access-key*
   #:*aws-session-token* #:*ses-configuration-set* #:*trust-proxy*
   #:*cookie-secure*
   ;; database
   #:db-open #:db-close #:with-db #:query #:query-one #:exec
   #:create-site #:site-by-key
   ;; email
   #:send-email #:*captured-emails* #:sigv4-authorization #:sigv4-signing-key
   ;; utilities (exported for tests / REPL use)
   #:canonical-page-url #:url-origin #:normalize-email #:parse-origins
   #:render-body #:iso-time #:sha256-hex #:random-token))
