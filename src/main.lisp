;;;; main.lisp — start/stop from the REPL, and the executable entry point.
;;;;
;;;; Two ways the same code runs:
;;;;  * Development: load the system in a REPL and call (start) / (stop).
;;;;    The server runs in background threads while the REPL stays usable,
;;;;    so redefining a function (C-c C-c in SLY) changes the live server.
;;;;  * Production: build.lisp saves an executable whose entry point is MAIN.
;;;;    MAIN reads the environment, calls START, then parks the main thread
;;;;    forever while Hunchentoot's threads serve requests.

(in-package #:rf-comments)

(defvar *acceptor* nil "The running Hunchentoot acceptor, if any.")

;;; Hunchentoot globals set here:
;;;   *HUNCHENTOOT-DEFAULT-EXTERNAL-FORMAT*  decode forms and encode bodies
;;;                                          as UTF-8. Current Hunchentoot
;;;                                          already defaults to UTF-8; it's
;;;                                          set explicitly because comments
;;;                                          in any language depend on it,
;;;                                          and globals can be changed by
;;;                                          other code in the image.
;;;   *DEFAULT-CONTENT-TYPE*                 name the charset in the header
;;;                                          too
;;;   *SHOW-LISP-ERRORS-P* NIL               never show backtraces to visitors
;;;   *REWRITE-FOR-SESSION-URLS* NIL         we don't use Hunchentoot sessions
;;; HT:START returns immediately; the acceptor runs in its own threads. The
;;; access log (one line per request) goes to stdout and errors to stderr,
;;; which is what `docker logs` collects.
(defun start (&key (port *port*) (address *address*) (db-path *db-path*))
  "Open the database and start serving. Safe to call again to restart."
  (when *acceptor* (stop))
  (setf ht:*hunchentoot-default-external-format* (flex:make-external-format :utf-8 :eol-style :lf)
        ht:*default-content-type* "text/html; charset=utf-8"
        ht:*show-lisp-errors-p* nil
        ht:*rewrite-for-session-urls* nil)
  (db-open db-path)
  (purge-expired)
  (setf *acceptor* (make-instance 'app-acceptor :port port :address address
                                                :access-log-destination *standard-output*
                                                :message-log-destination *error-output*))
  (ht:start *acceptor*)
  (format t "~&;; rf-comments listening on ~a:~d (public URL ~a, db ~a, email ~(~a~))~%"
          (or address "*") port *public-url* db-path *email-backend*)
  *acceptor*)

;;; :SOFT T lets in-flight requests finish before the listener closes.
(defun stop ()
  (when *acceptor*
    (ignore-errors (ht:stop *acceptor* :soft t))
    (setf *acceptor* nil))
  (db-close)
  t)

(defun healthcheck ()
  "`rf-comments healthcheck` — exit 0 if the local server answers /healthz.
Used by Docker's HEALTHCHECK so the image needs no curl."
  (uiop:quit
   (handler-case
       (if (string= "ok" (dex:get (format nil "http://127.0.0.1:~d/healthz" *port*)
                                  :proxy nil :connect-timeout 3 :read-timeout 3
                                  :keep-alive nil))
           0 1)
     (error () 1))))

(defun main ()
  "Entry point of the standalone executable (see build.lisp)."
  (handler-case
      (progn
        (load-config)
        (load-repl-config)
        (when (member "healthcheck" (uiop:command-line-arguments) :test #'string=)
          (healthcheck))
        (when (and (eq *email-backend* :log) (uiop:string-prefix-p "https://" *public-url*))
          (format *error-output* "~&;; WARNING: EMAIL_BACKEND=log — emails are only printed.~%"))
        (unless *admin-password*
          (format *error-output* "~&;; NOTE: ADMIN_PASSWORD unset — /admin is disabled.~%"))
        (push (lambda () (stop)) sb-ext:*exit-hooks*)
        (start)
        (maybe-start-slynk)
        (loop (sleep 3600)
              (ignore-errors (purge-expired))))
    (sb-sys:interactive-interrupt ()
      (stop)
      (uiop:quit 0))
    (error (e)
      (format *error-output* "~&;; fatal: ~a~%" e)
      (uiop:quit 1))))
