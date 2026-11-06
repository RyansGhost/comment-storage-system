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

(in-package #:rf-comments)

(defun observer-failed (generic-function condition)
  (format *error-output* "~&;; observer of ~(~a~) failed: ~a~%"
          (sb-mop:generic-function-name generic-function) condition))

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

(defmethod publish-comment :after (comment (by (eql :author)))
  (notify-admin-of-comment comment))
