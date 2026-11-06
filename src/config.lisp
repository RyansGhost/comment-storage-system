;;;; config.lisp — runtime configuration, read from environment variables.
;;;;
;;;; Every setting is a special variable so it can be inspected or rebound
;;;; from the REPL (and in tests) without touching the environment.
;;;;
;;;; ----------------------------------------------------------------------
;;;; Special variables, DEFVAR vs DEFPARAMETER, and threads
;;;; ----------------------------------------------------------------------
;;;; A variable defined with DEFVAR or DEFPARAMETER is *special* (dynamically
;;;; scoped). By convention its name wears *earmuffs*. Two things to know:
;;;;
;;;; 1. DEFVAR only assigns if the variable is unbound, while DEFPARAMETER
;;;;    always assigns. That's why settings use DEFVAR. When you reload this
;;;;    file in a live REPL (C-c C-k in SLY), values you've already set,
;;;;    e.g. (setf *admin-password* "admin") in dev/start.lisp, survive the
;;;;    reload. Constant-like tables elsewhere use DEFPARAMETER so edits to
;;;;    them do take effect on reload.
;;;;
;;;; 2. (let ((*port* 9000)) …) rebinds a special variable for the dynamic
;;;;    extent of that LET, but only in the current thread. Hunchentoot
;;;;    handles each request in a new thread, which sees the *global* value.
;;;;    So a server-wide setting must be changed with SETF, not LET. The
;;;;    tests' WITH-GLOBALS macro (tests/package.lisp) exists because of
;;;;    this.
;;;;
;;;; Why environment variables: the service runs in Docker, where env vars
;;;; (from docker-compose's env_file) are the standard way to configure a
;;;; container. LOAD-CONFIG is called once at startup by MAIN. In the REPL
;;;; you simply SETF the variables instead.

(in-package #:rf-comments)

(defvar *public-url* "http://localhost:8080"
  "External origin of the service, e.g. https://comments.ryanfleck.ca.
Used to build links in emails and to verify the Origin of POST requests.")
(defvar *port* 8080)
(defvar *address* nil "Interface to bind; NIL means all interfaces.")
(defvar *db-path* "data/comments.db")
(defvar *admin-password* nil "Admin password. NIL disables /admin.")
(defvar *admin-email* nil
  "Where to send \"new comment\" notifications. NIL disables them.")
(defvar *email-backend* :log
  "One of :SES (send through Amazon SES), :LOG (print to stdout) or
:CAPTURE (push onto *CAPTURED-EMAILS*; used by the tests).")
(defvar *avatars* :gravatar
  "Profile images: :GRAVATAR (proxied through /avatar/…) or :OFF.")
(defvar *avatar-default* "identicon"
  "Gravatar's d= fallback for addresses without a Gravatar: identicon, mp,
monsterid, wavatar, retro, robohash or blank.")
(defvar *ses-from* "Comments <comments@example.com>")
(defvar *aws-region* "us-east-1")
(defvar *aws-access-key-id* nil)
(defvar *aws-secret-access-key* nil)
(defvar *aws-session-token* nil)
(defvar *ses-configuration-set* nil)
(defvar *trust-proxy* nil
  "When true, the client IP is taken from the last X-Forwarded-For entry.")
(defvar *cookie-secure* nil "Mark cookies Secure (on automatically for https).")

;;; Tunables. Not read from the environment; change them here or SETF them
;;; from a REPL. Durations are in seconds.
(defvar *max-body-length* 5000)
(defvar *max-name-length* 60)
(defvar *token-ttl* (* 48 60 60) "Email link lifetime, seconds.")
(defvar *session-ttl* (* 90 24 60 60) "User session lifetime, seconds.")
(defvar *admin-session-ttl* (* 12 60 60))
(defvar *emails-per-hour* 5 "Max emails sent to one address per hour.")
(defvar *comments-per-window* 10 "Max comments per IP per *RATE-WINDOW*.")
(defvar *rate-window* (* 10 60))

;;; UIOP:GETENV is the portable way to read an environment variable (the
;;; standard has no such function). Treating "" like unset means
;;; `FOO=` in an .env file falls back to the default instead of producing an
;;; empty setting.
(defun env (name &optional default)
  (let ((value (uiop:getenv name)))
    (if (and value (plusp (length value))) value default)))

(defun env-bool (name &optional default)
  (let ((value (env name)))
    (if value
        (and (member (string-downcase value) '("1" "true" "yes" "on") :test #'string=) t)
        default)))

(defun strip-trailing-slash (s)
  (string-right-trim "/" s))

;;; Each variable's current value doubles as its default. A REPL user who
;;; set something before calling LOAD-CONFIG keeps it unless the
;;; environment overrides it.
;;;
;;; (intern (string-upcase "ses") :keyword) turns the string "ses" into the
;;; keyword :SES, so the rest of the code can use EQ / ECASE on keywords
;;; instead of comparing strings everywhere. The validation at the end then
;;; fails fast at startup, rather than on the first email or request.
(defun load-config ()
  "Populate the configuration variables from the environment."
  (setf *public-url* (strip-trailing-slash (env "PUBLIC_URL" *public-url*))
        *port* (parse-integer (env "PORT" (princ-to-string *port*)))
        *address* (env "BIND_ADDRESS" *address*)
        *db-path* (env "DB_PATH" *db-path*)
        *admin-password* (env "ADMIN_PASSWORD" *admin-password*)
        *admin-email* (env "ADMIN_EMAIL" *admin-email*)
        *email-backend* (intern (string-upcase (env "EMAIL_BACKEND" (string *email-backend*)))
                                :keyword)
        *avatars* (intern (string-upcase (env "AVATARS" (string *avatars*))) :keyword)
        *avatar-default* (env "AVATAR_DEFAULT" *avatar-default*)
        *ses-from* (env "SES_FROM" *ses-from*)
        *aws-region* (env "AWS_REGION" *aws-region*)
        *aws-access-key-id* (env "AWS_ACCESS_KEY_ID" *aws-access-key-id*)
        *aws-secret-access-key* (env "AWS_SECRET_ACCESS_KEY" *aws-secret-access-key*)
        *aws-session-token* (env "AWS_SESSION_TOKEN" *aws-session-token*)
        *ses-configuration-set* (env "SES_CONFIGURATION_SET" *ses-configuration-set*)
        *trust-proxy* (env-bool "TRUST_PROXY" *trust-proxy*)
        *cookie-secure* (env-bool "COOKIE_SECURE"
                                  (uiop:string-prefix-p "https://" *public-url*)))
  (unless (member *email-backend* '(:ses :log :capture))
    (error "EMAIL_BACKEND must be ses or log, not ~(~a~)" *email-backend*))
  (unless (member *avatars* '(:gravatar :off))
    (error "AVATARS must be gravatar or off, not ~(~a~)" *avatars*))
  (unless (member *avatar-default* '("identicon" "mp" "monsterid" "wavatar" "retro"
                                     "robohash" "blank")
                  :test #'string=)
    (error "AVATAR_DEFAULT must be one of identicon, mp, monsterid, wavatar, retro, ~
            robohash or blank"))
  (when (and (eq *email-backend* :ses)
             (not (and *aws-access-key-id* *aws-secret-access-key*)))
    (error "EMAIL_BACKEND=ses requires AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"))
  *public-url*)
