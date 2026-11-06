;;;; dev/start.lisp — boot a development server from the REPL.
;;;;
;;;;   M-x sly            (in Emacs, with the project open)
;;;;   (load "dev/start.lisp")
;;;;
;;;; or from a shell:   sbcl --load dev/start.lisp
;;;;
;;;; It registers the project with ASDF, loads it with Quicklisp, seeds a
;;;; "dev" site for http://localhost:8000 and starts the server on :8080
;;;; with emails printed to the REPL instead of sent.
;;;;
;;;; This is the "live system" workflow the book (Lisp for the Web) is built
;;;; around: the server runs inside your editor's Lisp, and every C-c C-c on a
;;;; DEFUN, DEFROUTE or DEFPAGE changes the running server instantly; no
;;;; restart, no lost state. Stop and start it with (stop) / (start).

;;; *LOAD-TRUENAME* is the path of the file being LOADed; from it we find
;;; the project root and tell ASDF to look there. It works no matter what
;;; directory the REPL was started in.
(let ((root (merge-pathnames "../" (make-pathname :name nil :type nil
                                                  :defaults (or *load-truename*
                                                                *default-pathname-defaults*)))))
  (pushnew (truename root) asdf:*central-registry* :test #'equal))

(ql:quickload :rf-comments :silent t)

(in-package #:rf-comments)

(setf *public-url* "http://localhost:8080"
      *port* 8080
      *db-path* "data/dev.db"
      *admin-password* "admin"
      *email-backend* :log
      *cookie-secure* nil)

(start)

(unless (site-by-key "dev")
  (create-site :key "dev" :name "Local development"
               :origins '("http://localhost:8000" "http://localhost:8080")))

(format t "~&;; Admin: http://localhost:8080/admin  (password: admin)~%~
           ;; Demo:  http://localhost:8080/thread?site=dev&page=http://localhost:8000/~%~
           ;; Tests: (asdf:test-system :rf-comments)~%")
