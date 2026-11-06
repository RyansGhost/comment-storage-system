;;;; web.lisp — public routes: embed script, comment thread, email
;;;; verification, magic-link login, profile, JSON API.

(in-package #:rf-comments)

(defclass app-acceptor (easy-routes:routes-acceptor) ()
  (:documentation "Hunchentoot acceptor serving only our easy-routes."))

(defparameter +user-cookie+ "rfc_session")
(defparameter +admin-cookie+ "rfc_admin")

;;; ------------------------------------------------------------------
;;; Static assets — read at load time so the saved executable has them.
;;; In the REPL, re-evaluate (reload-static) after editing static/*.js.

(defun static-path (name)
  (asdf:system-relative-pathname "rf-comments" (format nil "static/~a" name)))

(defvar *static* (make-hash-table :test #'equal))

(defun reload-static ()
  (dolist (name '("embed.js" "thread.js"))
    (setf (gethash name *static*) (uiop:read-file-string (static-path name)))))

(reload-static)

;;; Cookies

(defun set-cookie (name value &key (max-age *session-ttl*) (path "/") (same-site "Lax"))
  (ht:set-cookie name :value value :path path :max-age max-age :http-only t
                      :secure *cookie-secure* :same-site same-site))

(defun clear-cookie (name &key (path "/") (same-site "Lax"))
  (set-cookie name "" :max-age 0 :path path :same-site same-site))

(defun current-user ()
  (let ((session (find-session (ht:cookie-in +user-cookie+) "user")))
    (when session (user-by-id (getf session :user-id)))))

(defun sign-in (user-id)
  (set-cookie +user-cookie+ (create-session "user" :user-id user-id)))

;;; ------------------------------------------------------------------
;;; Thread (the iframe document)

(defun thread-path (site-key page title &key notice anchor)
  (format nil "/thread?~a~@[#~a~]"
          (query-string "site" site-key "page" page "title" (unless (blank-p title) title)
                        "notice" notice)
          anchor))

(defun frame-ancestors (site)
  (format nil "'self'~{ ~a~}" (getf site :origins)))

(defun unavailable-thread (message)
  (set-security-headers :frame-ancestors "*")
  (respond (html-page (:title "Comments" :css "")
             (:main.rf (:p.rf-empty message)))))

(defun render-thread (site page-url title &key user notice error form (status 200))
  (set-security-headers :frame-ancestors (frame-ancestors site))
  (let* ((comments (page-comments (getf site :id) page-url :viewer-id (getf user :id)))
         (published (count "published" comments :key (lambda (c) (getf c :status))
                                                :test #'string=))
         (here (thread-path (getf site :key) page-url title)))
    (respond
     (html-page (:title "Comments" :css "" :extra-css (theme-css site))
       (:main.rf
        (:h2 (format nil "~d comment~:p" published))
        (notice-html (notice-text notice))
        (notice-html error "error")
        (if comments
            (:ol.rf-list
             (dolist (c comments)
               (:li :id (format nil "c~d" (getf c :id))
                    :class (if (string= (getf c :status) "pending")
                               "rf-comment rf-pending" "rf-comment")
                    (:div.rf-meta
                     (:strong (getf c :display-name))
                     (:time :datetime (getf c :created-at) (human-date (getf c :created-at)))
                     (when (string= (getf c :status) "pending")
                       (:span.rf-badge "awaiting email confirmation")))
                    (comment-body-html (getf c :body)))))
            (:p.rf-empty "No comments yet. Start the conversation!"))
        (:form.rf-form :method "post" :action "/thread/comment"
         (:input :type "hidden" :name "site" :value (getf site :key))
         (:input :type "hidden" :name "page" :value page-url)
         (:input :type "hidden" :name "title" :value (or title ""))
         (if user
             (:p.rf-muted "Commenting as " (:strong (getf user :display-name)) " · "
                          (:a :href "/me" :target "_blank" "your profile") " · "
                          (:button.rf-link :type "submit" :form "rf-logout" "sign out"))
             (:div.rf-row
              (:label "Name"
                      (:input :name "name" :required t :maxlength *max-name-length*
                              :autocomplete "nickname" :value (getf form :name)))
              (:label "Email (never shown)"
                      (:input :type "email" :name "email" :required t :maxlength 254
                              :autocomplete "email" :value (getf form :email)))))
         (:label.rf-hp :aria-hidden "true" "Leave this empty"
                       (:input :name "website" :tabindex "-1" :autocomplete "off"))
         (:label "Comment"
                 (:textarea :name "body" :required t :rows 4 :maxlength *max-body-length*
                            (or (getf form :body) "")))
         (:div.rf-actions
          (:small (if user
                      "Plain text; blank lines start new paragraphs."
                      "We'll email you a link to confirm your comment."))
          (:button :type "submit" "Post comment")))
        (when user
          (:form :id "rf-logout" :class "rf-inline" :method "post" :action "/logout"
           (:input :type "hidden" :name "return" :value here)))
        (:p.rf-footer
         (if user
             ""
             (:span (:a :href "/login" :target "_blank" "Sign in")
                    " to see your profile and comments."))))
       (:script :src "/static/thread.js"))
     :status status)))

(defun resolve-thread (site-key page)
  "Return (values site page-url) or (values nil error-message)."
  (let ((site (and site-key (site-by-key site-key)))
        (page-url (canonical-page-url page)))
    (cond ((or (null site) (not (getf site :enabled)))
           (values nil "Comments are not enabled for this site."))
          ((null page-url) (values nil "This page can't be commented on."))
          ((not (site-allows-page-p site page-url))
           (values nil "Comments are not enabled for this domain."))
          (t (values site page-url)))))

(defpage thread ("/thread") (&get site page title notice)
  (multiple-value-bind (site page-url) (resolve-thread site page)
    (if site
        (render-thread site page-url (clean-title title) :user (current-user) :notice notice)
        (unavailable-thread page-url))))

(defaction post-comment ("/thread/comment")
    (&post site page title name email body website)
  (multiple-value-bind (site page-url) (resolve-thread site page)
    (unless site
      (return-from post-comment (unavailable-thread page-url)))
    (let* ((title (clean-title title))
           (user (current-user))
           (form (list :name name :email email :body body)))
      (flet ((fail (message &optional (status 422))
               (render-thread site page-url title :user user :error message :form form
                                                  :status status))
             (back-to-thread (&rest args)
               (redirect-to (apply #'thread-path (getf site :key) page-url title args))))
        ;; Bots fill in every field; humans never see this one.
        (unless (blank-p website)
          (return-from post-comment (back-to-thread :notice "check-email")))
        (when (rate-limited-p (list :comment (client-ip)) *comments-per-window* *rate-window*)
          (return-from post-comment
            (fail "You're commenting too quickly. Please wait a few minutes." 429)))
        (if user
            ;; Signed in: the email is already proven, publish immediately.
            (with-valid-inputs ((clean-body clean-body body))
                (:on-error (message) (fail message))
              (let ((id (create-comment :site-id (getf site :id) :user-id (getf user :id)
                                        :page-url page-url :page-title title :body clean-body
                                        :status "pending" :ip-hash (hash-ip (client-ip)))))
                (publish-comment (comment-by-id id) :author)
                (back-to-thread :notice "posted" :anchor (format nil "c~d" id))))
            (with-valid-inputs ((clean-body clean-body body)
                                (clean-name clean-display-name name)
                                (clean-email normalize-email email))
                (:on-error (message) (fail message))
              (let* ((user (find-or-create-user clean-email clean-name))
                     (id (create-comment :site-id (getf site :id) :user-id (getf user :id)
                                         :page-url page-url :page-title title
                                         :body clean-body :status "pending"
                                         :ip-hash (hash-ip (client-ip)))))
                (back-to-thread
                 :notice (cond ((>= (recent-email-count (getf user :id)) *emails-per-hour*)
                                "email-limit")
                               ((send-verification-email
                                 user id (issue-token (getf user :id) "verify" :comment-id id)
                                 page-url)
                                "check-email")
                               (t "email-failed"))))))))))

;;; ------------------------------------------------------------------
;;; Email confirmation. GET shows a button; POST does the work, so that
;;; link scanners in mail clients can't consume the single-use token.

(defun confirm-page (title message action token button &key excerpt redirect-origin)
  ;; Not "no-referrer": that makes browsers send "Origin: null" with the
  ;; form POST, which @SAME-ORIGIN (rightly) rejects. "same-origin" still
  ;; keeps the token-bearing URL from leaking to other sites.
  ;; CSP form-action also governs the redirect that follows the POST, so
  ;; the page we send the user back to must be allowed explicitly.
  (set-security-headers :form-action (format nil "'self'~@[ ~a~]" redirect-origin))
  (respond
   (html-page (:title title)
     (:main.page.narrow
      (:h1 title)
      (:p message)
      (when excerpt (:blockquote.rf-muted (truncate-string excerpt 280)))
      (:form :method "post" :action action
             (:input :type "hidden" :name "token" :value token)
             (:button :type "submit" button))))))

(defun expired-link ()
  (error-page 410 "Link expired"
              "This link has expired or has already been used. You can request a new sign-in link from the sign-in page."))

(defpage verify ("/verify" :decorators (@no-cache)) (&get token)
  (let ((tok (peek-token token "verify")))
    (if tok
        (let ((comment (comment-by-id (getf tok :comment-id))))
          (confirm-page "Confirm your comment"
                        (format nil "Publish your comment on ~a?"
                                (or (getf comment :page-url) "the page"))
                        "/verify" token "Publish my comment"
                        :excerpt (getf comment :body)
                        :redirect-origin (url-origin (getf comment :page-url))))
        (expired-link))))

(defaction verify-post ("/verify") (&post token)
  (let ((tok (consume-token token "verify")))
    (if (null tok)
        (expired-link)
        (let ((comment (comment-by-id (getf tok :comment-id))))
          (mark-user-verified (getf tok :user-id))
          (sign-in (getf tok :user-id))
          (when (and comment (string= (getf comment :status) "pending"))
            (publish-comment comment :author))
          (redirect-to (if comment
                           (format nil "~a#rf-comments" (getf comment :page-url))
                           "/me"))))))

;;; ------------------------------------------------------------------
;;; Magic-link login

(defun login-page (&key notice error (status 200) email)
  (respond
   (html-page (:title "Sign in")
     (:main.page.narrow
      (:h1 "Sign in")
      (notice-html notice)
      (notice-html error "error")
      (:p.rf-muted "Enter the email address you comment with and we'll send you a sign-in link.")
      (:form.rf-form :method "post" :action "/login"
       (:label "Email" (:input :type "email" :name "email" :required t :autofocus t
                               :autocomplete "email" :value email))
       (:div (:button :type "submit" "Email me a link")))))
   :status status))

(defpage login ("/login") (&get notice)
  (if (current-user)
      (redirect-to "/me")
      (login-page :notice (notice-text notice))))

(defaction login-post ("/login") (&post email)
  (when (rate-limited-p (list :login (client-ip)) 10 *rate-window*)
    (return-from login-post
      (login-page :error "Too many attempts. Please wait a few minutes." :status 429)))
  (with-valid-inputs ((clean normalize-email email))
      (:on-error (message) (login-page :error message :email email :status 422))
    (let ((user (user-by-email clean)))
      ;; Same answer whether or not the account exists.
      (when (and user (< (recent-email-count (getf user :id)) *emails-per-hour*))
        (send-login-email user (issue-token (getf user :id) "login")))
      (respond (simple-page "Check your inbox"
                            (format nil "If ~a has commented here, a sign-in link is on its way."
                                    clean))))))

(defpage login-callback ("/login/callback" :decorators (@no-cache)) (&get token)
  (if (peek-token token "login")
      (confirm-page "Sign in" "Continue to your profile?" "/login/callback" token "Sign in")
      (expired-link)))

(defaction login-callback-post ("/login/callback") (&post token)
  (let ((tok (consume-token token "login")))
    (if (null tok)
        (expired-link)
        (progn (mark-user-verified (getf tok :user-id))
               (sign-in (getf tok :user-id))
               (redirect-to "/me")))))

(defaction logout ("/logout") (&post return)
  (delete-session (ht:cookie-in +user-cookie+))
  (clear-cookie +user-cookie+)
  (redirect-to (if (local-path-p return) return "/login?notice=signed-out")))

;;; ------------------------------------------------------------------
;;; Profile

(defvar *user* nil "The signed-in user inside @USER routes.")

(defun @user (next)
  "Decorator: require a signed-in user, bound to *USER*."
  (let ((user (current-user)))
    (if user
        (let ((*user* user)) (funcall next))
        (redirect-to "/login"))))

(defpage me ("/me" :decorators (@user @no-cache)) (&get notice)
  (let ((comments (user-comments (getf *user* :id))))
    (respond
     (html-page (:title "Your comments")
       (:main.page
        (:nav (:strong "comments.ryanfleck.ca")
              (:form.rf-inline :method "post" :action "/logout"
                               (:button.rf-secondary :type "submit" "Sign out")))
        (:h1 (format nil "Hi, ~a" (getf *user* :display-name)))
        (notice-html (notice-text notice))
        (:form.rf-form :method "post" :action "/me/name"
         (:div.rf-row
          (:label "Display name"
                  (:input :name "name" :required t :maxlength *max-name-length*
                          :value (getf *user* :display-name)))
          (:label "Email" (:input :value (getf *user* :email) :disabled t)))
         (:div (:button :type "submit" "Save name")))
        (:p.rf-muted (format nil "Member since ~a." (human-date (getf *user* :created-at))))
        (:h2 (format nil "Your comments (~d)" (length comments)))
        (if (null comments)
            (:p.rf-empty "You haven't commented yet.")
            (:table
             (:thead (:tr (:th "Date") (:th "Page") (:th "Comment") (:th "Status") (:th "")))
             (:tbody
              (dolist (c comments)
                (:tr
                 (:td (human-date (getf c :created-at)))
                 (:td (:a :href (getf c :page-url) :target "_blank" :rel "noopener"
                          (if (blank-p (getf c :page-title))
                              (getf c :page-url)
                              (getf c :page-title))))
                 (:td (truncate-string (getf c :body) 160))
                 (:td (getf c :status))
                 (:td (:form :method "post"
                             :action (format nil "/me/comments/~d/delete" (getf c :id))
                             (:button.rf-danger :type "submit" "Delete")))))))))))))

(defaction me-name ("/me/name" :decorators (@user)) (&post name)
  (with-valid-inputs ((clean clean-display-name name))
      (:on-error (message) (declare (ignore message)) (redirect-to "/me"))
    (set-user-name (getf *user* :id) clean)
    (redirect-to "/me?notice=name-saved")))

(defaction me-delete ("/me/comments/:id/delete" :decorators (@user)) (&path (id 'integer))
  (let ((comment (comment-by-id id)))
    (when (and comment (eql (getf comment :user-id) (getf *user* :id)))
      (remove-comment comment :author))
    (redirect-to "/me?notice=deleted")))

;;; ------------------------------------------------------------------
;;; Assets, JSON API, health

(defun serve-js (name)
  (setf (ht:content-type*) "application/javascript; charset=utf-8"
        (ht:header-out "Cache-Control") "public, max-age=300"
        (ht:header-out "X-Content-Type-Options") "nosniff")
  (gethash name *static*))

(easy-routes:defroute embed-js ("/embed.js" :method :get) ()
  (serve-js "embed.js"))

(easy-routes:defroute thread-js ("/static/thread.js" :method :get) ()
  (serve-js "thread.js"))

(easy-routes:defroute api-comments ("/api/comments" :method :get) (&get site page)
  (setf (ht:content-type*) "application/json")
  (multiple-value-bind (site page-url) (resolve-thread site page)
    (if (null site)
        (progn (setf (ht:return-code*) 404)
               (jzon:stringify (alexandria:plist-hash-table (list "error" page-url)
                                                            :test #'equal)))
        (let ((origin (ht:header-in* :origin)))
          (when (and origin (member origin (getf site :origins) :test #'string=))
            (setf (ht:header-out "Access-Control-Allow-Origin") origin
                  (ht:header-out "Vary") "Origin"))
          (jzon:stringify
           (coerce
            (loop for c in (page-comments (getf site :id) page-url)
                  collect (alexandria:plist-hash-table
                           (list "id" (getf c :id) "author" (getf c :display-name)
                                 "body" (getf c :body) "created_at" (getf c :created-at))
                           :test #'equal))
            'vector))))))

(easy-routes:defroute healthz ("/healthz" :method :get) ()
  (setf (ht:content-type*) "text/plain")
  (handler-case (progn (query-one "SELECT 1") "ok")
    (error () (setf (ht:return-code*) 503) "database unavailable")))

(defpage home ("/") ()
  (respond
   (html-page (:title "Comments")
     (:main.page.narrow
      (:h1 "Comments")
      (:p "This is the tiny comment service behind ryanfleck.ca.")
      (:p (:a.rf-button :href "/login" "Sign in to see your comments"))))))
