;;;; package.lisp

(defpackage #:rf-comments
  (:use #:cl)
  (:local-nicknames (#:ht #:hunchentoot)
                    (#:jzon #:com.inuoe.jzon)
                    (#:bt #:bordeaux-threads))
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
