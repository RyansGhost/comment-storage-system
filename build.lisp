;;;; build.lisp — build the standalone executable bin/rf-comments.
;;;;
;;;;   sbcl --non-interactive --load build.lisp
;;;;
;;;; Expects Quicklisp to be installed (QUICKLISP_HOME, default ~/quicklisp/).

(require :asdf)

(let ((setup (merge-pathnames "setup.lisp"
                              (uiop:ensure-directory-pathname
                               (or (uiop:getenv "QUICKLISP_HOME")
                                   (merge-pathnames "quicklisp/" (user-homedir-pathname)))))))
  (unless (find-package :ql) (load setup)))

(push (uiop:getcwd) asdf:*central-registry*)
(uiop:symbol-call :ql :quickload :rf-comments)

(ensure-directories-exist "bin/")
(sb-ext:save-lisp-and-die "bin/rf-comments"
                          :executable t
                          :toplevel (lambda () (uiop:symbol-call :rf-comments :main))
                          :save-runtime-options nil
                          :compression (and (member :sb-core-compression *features*) t))
