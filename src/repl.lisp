;;;; repl.lisp — opt-in live REPL (Slynk) for the running service.
;;;;
;;;; "Lisp for the Web" grows the application inside a running Lisp. This
;;;; lets you do the same to production: attach SLY to the live container,
;;;; inspect state, redefine a function. It is ARBITRARY CODE EXECUTION,
;;;; so it is off unless SLYNK_PORT is set, refuses to start without
;;;; SLYNK_SECRET, and binds 127.0.0.1 unless SLYNK_INTERFACE says
;;;; otherwise (docker-compose.repl.yml publishes it to the host's
;;;; loopback only). Changes made this way vanish on restart: commit them.
;;;;
;;;; Slynk and its contribs are compiled into the executable by build.lisp.
;;;; It is not a dependency of the system itself, so this file never
;;;; refers to SLYNK symbols at read time.

(in-package #:rf-comments)

(defvar *slynk-port* nil "Port for the live REPL; NIL (the default) disables it.")
(defvar *slynk-interface* "127.0.0.1")
(defvar *slynk-secret* nil "Shared secret; SLY sends the first line of ~/.sly-secret.")

(defparameter +slynk-contribs+
  '("slynk/arglists" "slynk/fancy-inspector" "slynk/package-fu" "slynk/mrepl"
    "slynk/trace-dialog" "slynk/profiler" "slynk/stickers" "slynk/indentation")
  "Contribs SLY asks for on connect; preloaded because the executable has
no source tree or Quicklisp to load them from at run time.")

;;; Notice the code below never writes slynk:create-server literally. The
;;; reader resolves package prefixes when it *reads* a file, so mentioning
;;; SLYNK: here would make this file fail to load wherever Slynk isn't
;;; installed (tests without it, dev images). UIOP:SYMBOL-CALL and
;;; UIOP:FIND-SYMBOL* look the symbol up at *run* time instead, a common
;;; idiom for optional dependencies.
(defun load-repl-config ()
  (setf *slynk-port* (let ((p (env "SLYNK_PORT"))) (and p (parse-integer p)))
        *slynk-interface* (env "SLYNK_INTERFACE" *slynk-interface*)
        *slynk-secret* (env "SLYNK_SECRET" *slynk-secret*)))

;;; SB-POSIX gives direct access to POSIX calls (getpid, chmod, setenv). It's
;;; SBCL-specific, which is fine here: the production build targets SBCL.
(defun install-slynk-secret (secret)
  "Slynk reads the secret from (user-homedir-pathname)/.sly-secret on every
connection, so give this process a private HOME holding just that file."
  (let* ((home (format nil "/tmp/rf-comments-slynk-~d/" (sb-posix:getpid)))
         (file (concatenate 'string home ".sly-secret")))
    (ensure-directories-exist home)
    (sb-posix:chmod home #o700)
    (with-open-file (out file :direction :output :if-exists :supersede)
      (write-line secret out))
    (sb-posix:chmod file #o600)
    (sb-posix:setenv "HOME" home 1)
    (string= secret (uiop:symbol-call :slynk :sly-secret))))

(defvar *slynk-hardened* nil)

;;; Functions are first-class and global function definitions are just a
;;; mutable cell: (setf (fdefinition 'name) new-function) replaces what
;;; NAME calls everywhere, immediately. Wrapping a library's internal
;;; function this way is a small, local form of "advice" (cf. Emacs
;;; advice-add). It's fragile across library versions, so it's limited to
;;; the two functions we need and covered by tests.
(defun wrap-function (name wrapper)
  "Replace the function NAME with (lambda (&rest args) (funcall WRAPPER original args))."
  (let ((original (fdefinition name)))
    (setf (fdefinition name)
          (lambda (&rest args) (funcall wrapper original args)))))

(defun harden-slynk ()
  "Out of the box, a client with the wrong secret makes Slynk's accept
thread signal an unhandled error (which kills a non-interactive Lisp) and
leaks the client socket. Close the socket and keep serving instead."
  (unless *slynk-hardened*
    (wrap-function (uiop:find-symbol* :authenticate-client :slynk)
                   (lambda (original args)
                     (handler-bind ((error (lambda (e)
                                             (declare (ignore e))
                                             (ignore-errors (close (first args) :abort t)))))
                       (apply original args))))
    (wrap-function (uiop:find-symbol* :accept-connections :slynk)
                   (lambda (original args)
                     (handler-case (apply original args)
                       (error (e)
                         (format *error-output* "~&;; REPL connection rejected: ~a~%" e)
                         nil))))
    (setf *slynk-hardened* t)))

(defun maybe-start-slynk (&key (port *slynk-port*) (interface *slynk-interface*)
                            (secret *slynk-secret*))
  "Start Slynk when configured. Returns the port, or NIL if not started."
  (cond ((null port) nil)
        ((not (find-package :slynk))
         (format *error-output* "~&;; SLYNK_PORT is set but Slynk is not built in; no REPL.~%")
         nil)
        ((or (null secret) (< (length secret) 16))
         (format *error-output* "~&;; SLYNK_PORT is set but SLYNK_SECRET is missing or shorter ~
                                    than 16 characters; refusing to start the REPL.~%")
         nil)
        ((not (install-slynk-secret secret))
         (format *error-output* "~&;; Could not install the Slynk secret; no REPL.~%")
         nil)
        (t
         (harden-slynk)
         (prog1 (uiop:symbol-call :slynk :create-server :port port :interface interface
                                                        :dont-close t)
           (format *error-output* "~&;; !!! LIVE REPL listening on ~a:~d (Slynk). Anyone who ~
                                      can reach it and knows the secret can run any code. ~
                                      Turn it off when you're done. !!!~%"
                   interface port)))))
