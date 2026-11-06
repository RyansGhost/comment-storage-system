;;;; tests/package.lisp
;;;;
;;;; ----------------------------------------------------------------------
;;;; FiveAM in five minutes
;;;; ----------------------------------------------------------------------
;;;;   (def-suite all)               a named suite; suites nest (:in all)
;;;;   (in-suite unit)               later TESTs in this file go into UNIT
;;;;   (test name body…)             defines a test (it is not run yet)
;;;;   (is (= 2 (+ 1 1)))            one *check*: records pass or fail and
;;;;                                 keeps going, so one test reports every
;;;;                                 failing check, not just the first
;;;;   (is (has "x" y) "msg ~a" z)   optional failure message
;;;;   (run! 'all)                   run a suite (or one test), print a
;;;;                                 report, return T only if all passed
;;;;
;;;; From the REPL: (rf-comments/tests:run-tests), or
;;;; (fiveam:run! 'rf-comments/tests::magic-link-login) for one test. From
;;;; a shell: `make test`. Tests are code, so you can also just call a test's
;;;; helpers in the REPL to poke at things.
;;;;
;;;; The suite is split into three files: unit (pure functions + data
;;;; model, in-memory DB), sigv4 (AWS request signing against known
;;;; vectors) and integration (a real HTTP server driven over the network).

(defpackage #:rf-comments/tests
  (:use #:cl #:fiveam)
  (:import-from #:rf-comments
                #:canonical-page-url #:url-origin #:parse-origins #:normalize-email
                #:render-body #:iso-time #:sha256-hex #:random-token)
  (:export #:all #:run-tests))

(in-package #:rf-comments/tests)

(def-suite all :description "All rf-comments tests.")

(defun run-tests ()
  "Run every test; returns true when all pass. Handy from the REPL."
  (run! 'all))

;;; Why this macro exists (see also config.lisp): the integration tests
;;; change settings such as *EMAIL-BACKEND*, but the code under test runs in
;;; Hunchentoot's request threads. A LET binding is visible only in the
;;; thread that made it, so the server would never see it. SETF changes the
;;; global value that every thread sees. UNWIND-PROTECT puts the old values
;;; back even if the test fails or errors, so one test can't leak settings
;;; into the next. (The trade-off: tests that use it must not run in
;;; parallel, and FiveAM runs tests sequentially.)
(defmacro with-globals ((&rest bindings) &body body)
  "Like LET for special variables, but SETFs the global value so that other
threads (Hunchentoot workers) see it too; restores the old values after."
  (let ((saved (loop repeat (length bindings) collect (gensym "OLD"))))
    `(let ,(loop for (var) in bindings for s in saved collect `(,s ,var))
       (unwind-protect
            (progn (setf ,@(loop for (var val) in bindings append `(,var ,val)))
                   ,@body)
         (setf ,@(loop for (var) in bindings for s in saved append `(,var ,s)))))))

(defmacro with-temp-db ((&optional (path ":memory:")) &body body)
  "Run BODY against a fresh database, restoring any previously open one."
  `(let ((old-db rf-comments::*db*))
     (setf rf-comments::*db* nil)
     (unwind-protect
          (progn (let ((*standard-output* (make-broadcast-stream)))
                   (rf-comments:db-open ,path))
                 ,@body)
       (rf-comments:db-close)
       (setf rf-comments::*db* old-db))))
