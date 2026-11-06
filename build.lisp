;;;; build.lisp — build the standalone executable bin/rf-comments.
;;;;
;;;;   sbcl --non-interactive --load build.lisp
;;;;
;;;; Expects Quicklisp to be installed (QUICKLISP_HOME, default ~/quicklisp/).
;;;;
;;;; How Lisp "compiles to a binary": unlike C, there is no separate link
;;;; step. You load everything into a running Lisp image (code, compiled
;;;; functions, data such as the static JS files already read into memory),
;;;; then SB-EXT:SAVE-LISP-AND-DIE writes that whole heap to disk together
;;;; with the SBCL runtime. Starting the executable maps the heap back in,
;;;; with no compile or load phase, so start-up takes milliseconds. The
;;;; result needs no Quicklisp, sources or SBCL install at run time, only
;;;; the C libraries it was linked against (libsqlite3, libssl), which the
;;;; Docker runtime stage installs.

(require :asdf)

(let ((setup (merge-pathnames "setup.lisp"
                              (uiop:ensure-directory-pathname
                               (or (uiop:getenv "QUICKLISP_HOME")
                                   (merge-pathnames "quicklisp/" (user-homedir-pathname)))))))
  (unless (find-package :ql) (load setup)))

;;; ASDF:*CENTRAL-REGISTRY* is a list of directories ASDF searches for .asd
;;; files; pushing the current directory lets QUICKLOAD find rf-comments.asd.
;;; (Developers usually symlink the project into ~/quicklisp/local-projects/
;;; instead; see the README.)
(push (uiop:getcwd) asdf:*central-registry*)
(uiop:symbol-call :ql :quickload :rf-comments)
;; The opt-in live REPL (src/repl.lisp): Slynk plus the contribs SLY loads
;; on connect, since the executable cannot load sources at run time.
(uiop:symbol-call :ql :quickload
                  (cons "slynk" (symbol-value (uiop:find-symbol* :+slynk-contribs+ :rf-comments))))

;;; SAVE-LISP-AND-DIE options:
;;;   :EXECUTABLE T             include the runtime, producing one runnable file
;;;   :TOPLEVEL                 function to call at start-up instead of the REPL
;;;   :SAVE-RUNTIME-OPTIONS NIL keep accepting runtime flags such as
;;;                             --dynamic-space-size
;;;   :COMPRESSION              zstd-compress the heap when this SBCL supports
;;;                             it (Debian's does): ~16 MB instead of ~100 MB,
;;;                             for a fraction of a second at start-up
;;; It must run in a Lisp with a single thread (no running server).
(ensure-directories-exist "bin/")
(sb-ext:save-lisp-and-die "bin/rf-comments"
                          :executable t
                          :toplevel (lambda () (uiop:symbol-call :rf-comments :main))
                          :save-runtime-options nil
                          :compression (and (member :sb-core-compression *features*) t))
