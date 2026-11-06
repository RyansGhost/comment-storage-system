;;;; config.lisp — runtime configuration, read from environment variables.
;;;;
;;;; Every setting is a special variable so it can be inspected or rebound
;;;; from the REPL (and in tests) without touching the environment.

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
(defvar *ses-from* "Comments <comments@example.com>")
(defvar *aws-region* "us-east-1")
(defvar *aws-access-key-id* nil)
(defvar *aws-secret-access-key* nil)
(defvar *aws-session-token* nil)
(defvar *ses-configuration-set* nil)
(defvar *trust-proxy* nil
  "When true, the client IP is taken from the last X-Forwarded-For entry.")
(defvar *cookie-secure* nil "Mark cookies Secure (on automatically for https).")

;;; Tunables
(defvar *max-body-length* 5000)
(defvar *max-name-length* 60)
(defvar *token-ttl* (* 48 60 60) "Email link lifetime, seconds.")
(defvar *session-ttl* (* 90 24 60 60) "User session lifetime, seconds.")
(defvar *admin-session-ttl* (* 12 60 60))
(defvar *emails-per-hour* 5 "Max emails sent to one address per hour.")
(defvar *comments-per-window* 10 "Max comments per IP per *RATE-WINDOW*.")
(defvar *rate-window* (* 10 60))

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
  (when (and (eq *email-backend* :ses)
             (not (and *aws-access-key-id* *aws-secret-access-key*)))
    (error "EMAIL_BACKEND=ses requires AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"))
  *public-url*)
