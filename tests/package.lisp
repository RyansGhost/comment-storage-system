;;;; tests/package.lisp

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
