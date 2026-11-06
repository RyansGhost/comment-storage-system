;;;; events.lisp — comment operations as generic functions, with side
;;;; effects attached as :AFTER methods ("observers for free", Lisp for
;;;; the Web ch. 4).
;;;;
;;;; The primary method of each operation changes the database and nothing
;;;; else. Everything that should *also* happen (audit log, notifying the
;;;; admin) is an :AFTER method, so new reactions can be added, from a file
;;;; or a live REPL, without touching the operation or its callers:
;;;;
;;;;   (defmethod publish-comment :after (comment (by (eql :author)))
;;;;     (tweet-about comment))
;;;;
;;;; These generic functions use the OBSERVED method combination: the
;;;; standard combination, except that each :AFTER method runs in its own
;;;; error handler. A failing observer is logged and never breaks the
;;;; request (or the other observers).
;;;;
;;;; COMMENT arguments are rows from COMMENT-BY-ID (plists). BY is who
;;;; acted: :AUTHOR (the commenter) or :ADMIN.
;;;;
;;;; ----------------------------------------------------------------------
;;;; CLOS refresher: generic functions and the standard method combination
;;;; ----------------------------------------------------------------------
;;;; In CLOS, methods belong to *generic functions*, not to classes. Calling
;;;; a generic function selects the *applicable* methods by the classes (or
;;;; EQL values) of all its arguments, then combines them. In the standard
;;;; method combination that means:
;;;;   :AROUND methods (outermost; each may CALL-NEXT-METHOD)
;;;;   → all :BEFORE methods, most specific first
;;;;   → the most specific *primary* method (its value is the call's value)
;;;;   → all :AFTER methods, most specific *last*
;;;; An unspecialised parameter, like COMMENT here, is specialised on T,
;;;; which matches anything, so plists work without defining classes.
;;;;
;;;; Why not a hooks list, or an explicit "notify" call inside each
;;;; operation? With CLOS the extension point is part of the language: the
;;;; caller just calls (publish-comment c :author), and anyone can add
;;;; behaviour by defining a method, including at the live REPL (see
;;;; repl.lisp). Removing a behaviour is (remove-method …). This is the
;;;; book's "Observer pattern in one line" point.

(in-package #:rf-comments)

(defun observer-failed (generic-function condition)
  (format *error-output* "~&;; observer of ~(~a~) failed: ~a~%"
          (sb-mop:generic-function-name generic-function) condition))

;;; DEFINE-METHOD-COMBINATION, long form. This is the most advanced CLOS
;;; feature in the project, so here it is step by step:
;;;
;;;  * The method-group specifiers (around (:around)) … sort the applicable
;;;    methods into lists by their qualifiers. PRIMARY has no qualifier and
;;;    is :REQUIRED (calling with no applicable primary method is an error).
;;;    Each list is ordered most specific first.
;;;  * (:generic-function gf) binds GF to the generic function object, so the
;;;    effective method can name it in the log message.
;;;  * The body returns a *form*: the "effective method" CLOS compiles and
;;;    runs for this combination of methods. Inside it:
;;;      (call-method M NEXT-METHODS)  runs method M; NEXT-METHODS is what
;;;                                    CALL-NEXT-METHOD inside M will call
;;;      (make-method FORM)            wraps an arbitrary form as a method,
;;;                                    used to make "everything inside the
;;;                                    :AROUNDs" the next method of the
;;;                                    outermost :AROUND
;;;  * Our only change from the standard combination (compare CLHS
;;;    DEFINE-METHOD-COMBINATION's example) is the HANDLER-CASE around each
;;;    :AFTER method. :AFTER runs most-specific-last, hence (reverse after).
;;;    MULTIPLE-VALUE-PROG1 keeps the primary method's return values.
;;;
;;; Errors in :BEFORE or primary methods still propagate, as they should:
;;; if the database update fails, the request must fail too.
(define-method-combination observed ()
  ((around (:around))
   (before (:before))
   (primary () :required t)
   (after (:after)))
  (:generic-function gf)
  "Standard method combination, but :AFTER methods are isolated observers."
  (let ((form `(multiple-value-prog1
                   (progn ,@(loop for m in before collect `(call-method ,m))
                          (call-method ,(first primary) ,(rest primary)))
                 ,@(loop for m in (reverse after)
                         collect `(handler-case (call-method ,m)
                                    (error (e) (observer-failed ,gf e)))))))
    (if around
        `(call-method ,(first around) (,@(rest around) (make-method ,form)))
        form)))

;;; ------------------------------------------------------------------
;;; Operations (primary methods: state changes only)
;;;
;;; DEFGENERIC declares the generic function and its lambda list once, and
;;; :METHOD-COMBINATION OBSERVED opts into the combination above. (Plain
;;; DEFMETHOD with no DEFGENERIC would create a generic function implicitly,
;;; but with the standard combination.)

(defgeneric publish-comment (comment by)
  (:method-combination observed)
  (:documentation "Make COMMENT visible on its page."))

(defgeneric hide-comment (comment by)
  (:method-combination observed)
  (:documentation "Hide COMMENT from its page (moderation)."))

(defgeneric remove-comment (comment by)
  (:method-combination observed)
  (:documentation "Delete COMMENT permanently."))

(defmethod publish-comment (comment by)
  (declare (ignore by))
  (set-comment-status (getf comment :id) "published"))

(defmethod hide-comment (comment by)
  (declare (ignore by))
  (set-comment-status (getf comment :id) "hidden"))

(defmethod remove-comment (comment by)
  (declare (ignore by))
  (delete-comment (getf comment :id)))

;;; ------------------------------------------------------------------
;;; Observer: moderation / audit log (every operation, every actor)
;;;
;;; Note that we can't define two :AFTER methods with the same qualifiers and
;;; specializers on one generic function; the second would simply *replace*
;;; the first. So the log takes the general (comment by) slot, and the
;;; notification below specialises BY with EQL to get a distinct slot.

(defun comment-summary (comment)
  (format nil "~a on ~a: ~a"
          (getf comment :display-name) (getf comment :page-url)
          (truncate-string (substitute #\Space #\Newline (getf comment :body)) 80)))

(defun log-moderation (comment action by)
  (exec "INSERT INTO moderation_log (comment_id, action, actor, summary, created_at)
         VALUES (?, ?, ?, ?, ?)"
        (getf comment :id) action (string-downcase (string by))
        (comment-summary comment) (iso-time)))

(defun recent-moderation (&optional (limit 50))
  (query (format nil "SELECT * FROM moderation_log ORDER BY id DESC LIMIT ~d" limit)))

(defmethod publish-comment :after (comment by)
  (log-moderation comment "publish" by))

(defmethod hide-comment :after (comment by)
  (log-moderation comment "hide" by))

(defmethod remove-comment :after (comment by)
  (log-moderation comment "delete" by))

;;; ------------------------------------------------------------------
;;; Observer: tell the admin when a commenter publishes something.
;;; Specialised on BY, so the admin's own moderation never emails them.

(defun notify-admin-of-comment (comment)
  (when *admin-email*
    (link-email *admin-email*
                :subject (format nil "New comment by ~a" (getf comment :display-name))
                :intro (format nil "~a (~a) commented on ~a:~%~%~a"
                               (getf comment :display-name) (getf comment :email)
                               (if (blank-p (getf comment :page-title))
                                   (getf comment :page-url)
                                   (format nil "\"~a\" (~a)" (getf comment :page-title)
                                           (getf comment :page-url)))
                               (truncate-string (getf comment :body) 1000))
                :link (format nil "~a/admin?status=published" *public-url*)
                :button "Moderate comments"
                :outro (format nil "Comment #~d on site ~a." (getf comment :id)
                               (getf comment :site-key)))))

;;; (by (eql :author)) is an *EQL specializer*: this method is applicable
;;; only when BY is the keyword :AUTHOR. That replaces an explicit
;;; (when (eq by :author) …) test, and makes "admin actions don't notify"
;;; a fact of dispatch.
(defmethod publish-comment :after (comment (by (eql :author)))
  (notify-admin-of-comment comment))
