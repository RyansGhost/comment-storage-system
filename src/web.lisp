;;;; web.lisp — public routes: embed script, comment thread, email
;;;; verification, magic-link login, profile, JSON API.
;;;;
;;;; The public half of the service. Routes, by audience:
;;;;   embedding pages   /embed.js, /count.js, /api/comments, /api/counts
;;;;   the iframe        /thread (GET), /thread/comment (POST),
;;;;                     /static/thread.js, /avatar/:key
;;;;   email links       /verify, /login/callback (GET confirm + POST act)
;;;;   people            /login, /logout, /me…
;;;;   operations        /healthz
;;;;
;;;; How embedding works (see static/embed.js): a blog page includes our
;;;; script, which adds an <iframe src="https://comments…/thread?site=…&page=…">.
;;;; Everything inside the frame is a normal server-rendered page from *our*
;;;; origin: its CSS can't leak into the blog or vice versa, and its forms
;;;; post to us directly with our cookies. Since the blogs are
;;;; *.ryanfleck.ca subdomains, the iframe is *same-site* with them, so
;;;; browsers that block third-party cookies still send ours.

(in-package #:rf-comments)

;;; A subclass rather than using EASY-ROUTES:ROUTES-ACCEPTOR directly gives
;;; us a named class to specialise later (e.g. a custom 404 page via
;;; HUNCHENTOOT:ACCEPTOR-STATUS-MESSAGE) without touching main.lisp.
;;; ROUTES-ACCEPTOR (unlike EASY-ROUTES-ACCEPTOR) serves *only* our routes:
;;; no fallback to Hunchentoot's static-file and easy-handler dispatch, so
;;; nothing is reachable by accident.
(defclass app-acceptor (easy-routes:routes-acceptor) ()
  (:documentation "Hunchentoot acceptor serving only our easy-routes."))

(defparameter +user-cookie+ "rfc_session")
(defparameter +admin-cookie+ "rfc_admin")

;;; ------------------------------------------------------------------
;;; Static assets — read at load time so the saved executable has them.
;;; In the REPL, re-evaluate (reload-static) after editing static/*.js.

;;; ASDF:SYSTEM-RELATIVE-PATHNAME finds files relative to the .asd, wherever
;;; the project is checked out. RELOAD-STATIC runs at *load* time (the
;;; top-level call below), so the file contents are captured in *STATIC* and
;;; saved inside the executable by SAVE-LISP-AND-DIE; the Docker runtime
;;; image has no source tree at all.
(defun static-path (name)
  (asdf:system-relative-pathname "rf-comments" (format nil "static/~a" name)))

(defvar *static* (make-hash-table :test #'equal))

(defun reload-static ()
  (dolist (name '("embed.js" "thread.js" "count.js"))
    (setf (gethash name *static*) (uiop:read-file-string (static-path name)))))

(reload-static)

;;; Cookies
;;;
;;; HT:SET-COOKIE adds a Set-Cookie header to the current reply. Attributes:
;;;   HttpOnly   JavaScript can't read it, so a script injected into some
;;;              page could not steal the session
;;;   Secure     only sent over HTTPS (on automatically for https PUBLIC_URL)
;;;   SameSite   Lax: sent on same-site requests and top-level navigations,
;;;              which covers our iframe on *.ryanfleck.ca. The admin cookie
;;;              uses Strict and Path=/admin.
;;;   Max-Age    lifetime in seconds; 0 deletes the cookie

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

(defun thread-path (site-key page title &key page-id notice anchor)
  (format nil "/thread?~a~@[#~a~]"
          (query-string "site" site-key "page" page "id" page-id
                        "title" (unless (blank-p title) title) "notice" notice)
          anchor))

(defun frame-ancestors (site)
  (format nil "'self'~{ ~a~}" (getf site :origins)))

(defun unavailable-thread (message)
  (set-security-headers :frame-ancestors "*")
  (respond (html-page (:title "Comments" :css "")
             (:main.rf (:p.rf-empty message)))))

;;; RENDER-THREAD is a function rather than inline in the route because two
;;; routes need it: GET /thread, and POST /thread/comment when validation
;;; fails (re-render with the error and the user's input preserved, status
;;; 422). It's also where the frame-ancestors CSP is narrowed to the site's
;;; own origins, so only those pages can embed this thread.
(defun render-thread (site page-url title &key page-id thread user notice error form
                                                (status 200))
  (set-security-headers :frame-ancestors (frame-ancestors site))
  (let* ((comments (page-comments (getf thread :id) :viewer-id (getf user :id)))
         (published (count "published" comments :key (lambda (c) (getf c :status))
                                                :test #'string=))
         (here (thread-path (getf site :key) page-url title :page-id page-id)))
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
                    (let ((avatar (avatar-path (getf c :avatar-key))))
                      (when avatar
                        (:img.rf-avatar :src avatar :alt "" :width 40 :height 40
                                        :loading "lazy")))
                    (:div.rf-main
                     (:div.rf-meta
                      (:strong (getf c :display-name))
                      (:time :datetime (getf c :created-at) (human-date (getf c :created-at)))
                      (when (string= (getf c :status) "pending")
                        (:span.rf-badge "awaiting email confirmation")))
                     (comment-body-html (getf c :body))))))
            (:p.rf-empty "No comments yet. Start the conversation!"))
        (:form.rf-form :method "post" :action "/thread/comment"
         (:input :type "hidden" :name "site" :value (getf site :key))
         (:input :type "hidden" :name "page" :value page-url)
         (when page-id (:input :type "hidden" :name "id" :value page-id))
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
         (unless user
           (:span (:a :href "/login" :target "_blank" "Sign in")
                  " to see your profile and comments."))
         (when (eq *avatars* :gravatar)
           (:span.rf-attribution
            "Profile images are provided by "
            (:a :href "https://gravatar.com" :target "_blank" :rel "noopener noreferrer"
                "Gravatar")
            "."))))
       (:script :src "/static/thread.js"))
     :status status)))

;;; Every thread request carries untrusted ?site= and ?page= values, so this
;;; is the gatekeeper: the site must exist and be enabled, the page must be
;;; an http(s) URL, and its origin must be one of the site's allowed
;;; origins. Errors come back as (values nil message), the same convention
;;; as the CLEAN-* functions.
(defun resolve-thread (site-key page &optional raw-page-id)
  "Return (values site page-url page-id page-key), or (values nil error-message).
The thread key is the embed's data-page-id when given, else the page URL."
  (let ((site (and site-key (site-by-key site-key)))
        (page-url (canonical-page-url page))
        (page-id (unless (blank-p raw-page-id) (clean-page-id raw-page-id))))
    (cond ((or (null site) (not (getf site :enabled)))
           (values nil "Comments are not enabled for this site."))
          ((null page-url) (values nil "This page can't be commented on."))
          ((not (site-allows-page-p site page-url))
           (values nil "Comments are not enabled for this domain."))
          ((and (not (blank-p raw-page-id)) (null page-id))
           (values nil "This page's comment id is invalid."))
          (t (values site page-url page-id (or page-id page-url))))))

(defpage thread ("/thread") (&get site page id title notice)
  (multiple-value-bind (site page-url page-id key) (resolve-thread site page id)
    (if (null site)
        (unavailable-thread page-url)
        (let* ((title (clean-title title))
               (thread (thread-by-key (getf site :id) key)))
          ;; A thread keyed by page id follows its page when the URL changes.
          (when (and thread page-id)
            (setf thread (ensure-thread (getf site :id) key page-url title)))
          (render-thread site page-url title :page-id page-id :thread thread
                                             :user (current-user) :notice notice)))))

;;; The heart of the service. Steps, in order:
;;;   1. resolve the site and page (or show "not enabled")
;;;   2. honeypot: a hidden "website" field humans never fill in; bots fill
;;;      every field. Pretend success, store nothing.
;;;   3. per-IP rate limit
;;;   4. validate the inputs (WITH-VALID-INPUTS)
;;;   5a. signed in: create the comment and publish it immediately (the
;;;       session already proves the email)
;;;   5b. anonymous: create it as pending and email a verification link.
;;;       The comment stays invisible until that link is used.
;;; FLET defines local helper functions: FAIL re-renders the form with an
;;; error, BACK-TO-THREAD redirects (Post/Redirect/Get), and THREAD-ID
;;; creates the thread row only once a comment really exists.
(defaction post-comment ("/thread/comment")
    (&post site page id title name email body website)
  (multiple-value-bind (site page-url page-id key) (resolve-thread site page id)
    (unless site
      (return-from post-comment (unavailable-thread page-url)))
    (let* ((title (clean-title title))
           (user (current-user))
           (form (list :name name :email email :body body)))
      (flet ((fail (message &optional (status 422))
               (render-thread site page-url title :page-id page-id
                                                  :thread (thread-by-key (getf site :id) key)
                                                  :user user :error message :form form
                                                  :status status))
             (back-to-thread (&rest args)
               (redirect-to (apply #'thread-path (getf site :key) page-url title
                                   :page-id page-id args)))
             (thread-id ()
               (getf (ensure-thread (getf site :id) key page-url title) :id)))
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
              (let ((id (create-comment :site-id (getf site :id) :thread-id (thread-id)
                                        :user-id (getf user :id)
                                        :page-url page-url :page-title title :body clean-body
                                        :status "pending" :ip-hash (hash-ip (client-ip)))))
                (publish-comment (comment-by-id id) :author)
                (back-to-thread :notice "posted" :anchor (format nil "c~d" id))))
            (with-valid-inputs ((clean-body clean-body body)
                                (clean-name clean-display-name name)
                                (clean-email normalize-email email))
                (:on-error (message) (fail message))
              (let* ((user (find-or-create-user clean-email clean-name))
                     (id (create-comment :site-id (getf site :id) :thread-id (thread-id)
                                         :user-id (getf user :id)
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

;;; Why not act on the GET itself? Corporate mail filters and some clients
;;; "pre-click" every link in an email to scan it. A GET that publishes or
;;; signs in would be triggered by the scanner (and the single-use token
;;; burnt), so the link only shows a button, and the POST it submits does
;;; the work. Scanners don't submit forms.
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
                        :redirect-origin (url-origin (getf comment :link-url))))
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
                           (format nil "~a#rf-comments" (getf comment :link-url))
                           "/me"))))))

;;; ------------------------------------------------------------------
;;; Magic-link login
;;;
;;; Passwordless sign-in: enter your email, receive a one-time link, click,
;;; confirm, and you're in. The answer is identical whether or not the
;;; address has an account, so the form can't be used to discover who
;;; comments here (no "account enumeration").

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

;;; @USER shows how decorators pass data inward: it binds the special
;;; variable *USER* around (funcall next), so the route body can use *USER*
;;; directly. The binding is per thread and per request, and disappears
;;; when the request ends.
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
        (:div.rf-hello
         (let ((avatar (avatar-path (getf *user* :avatar-key))))
           (when avatar (:img.rf-avatar :src avatar :alt "" :width 40 :height 40)))
         (:h1 (format nil "Hi, ~a" (getf *user* :display-name))))
        (notice-html (notice-text notice))
        (:form.rf-form :method "post" :action "/me/name"
         (:div.rf-row
          (:label "Display name"
                  (:input :name "name" :required t :maxlength *max-name-length*
                          :value (getf *user* :display-name)))
          (:label "Email" (:input :value (getf *user* :email) :disabled t)))
         (:div (:button :type "submit" "Save name")))
        (:p.rf-muted (format nil "Member since ~a." (human-date (getf *user* :created-at))))
        (when (eq *avatars* :gravatar)
          (:p.rf-muted "Your profile image comes from "
                       (:a :href "https://gravatar.com" :target "_blank"
                           :rel "noopener noreferrer" "Gravatar")
                       (format nil ". To set or change it, sign in there with ~a."
                               (getf *user* :email))))
        (:h2 (format nil "Your comments (~d)" (length comments)))
        (if (null comments)
            (:p.rf-empty "You haven't commented yet.")
            (:table
             (:thead (:tr (:th "Date") (:th "Page") (:th "Comment") (:th "Status") (:th "")))
             (:tbody
              (dolist (c comments)
                (:tr
                 (:td (human-date (getf c :created-at)))
                 (:td (:a :href (getf c :link-url) :target "_blank" :rel "noopener"
                          (if (blank-p (getf c :page-title))
                              (getf c :link-url)
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

;;; Non-HTML responses: set Content-Type explicitly and return the body. A
;;; short public cache (5 minutes) lets browsers reuse embed.js while still
;;; picking up changes quickly after a deploy.
(defun serve-js (name)
  (setf (ht:content-type*) "application/javascript; charset=utf-8"
        (ht:header-out "Cache-Control") "public, max-age=300"
        (ht:header-out "X-Content-Type-Options") "nosniff")
  (gethash name *static*))

(easy-routes:defroute embed-js ("/embed.js" :method :get) ()
  (serve-js "embed.js"))

(easy-routes:defroute thread-js ("/static/thread.js" :method :get) ()
  (serve-js "thread.js"))

(easy-routes:defroute count-js ("/count.js" :method :get) ()
  (serve-js "count.js"))

;;; Returning an octet vector (raw image bytes) from a route works just like
;;; returning a string: Hunchentoot writes it as the body. KEY is bound from
;;; the :key segment of the URL template.
(easy-routes:defroute avatar ("/avatar/:key" :method :get) ()
  (let ((user (and (eq *avatars* :gravatar)
                   (<= 1 (length key) 64)
                   (user-by-avatar-key key))))
    (if (null user)
        (progn (setf (ht:return-code*) 404
                     (ht:content-type*) "text/plain")
               "not found")
        (multiple-value-bind (data content-type long-lived) (avatar-image user)
          (setf (ht:content-type*) content-type
                (ht:header-out "Cache-Control") (if long-lived
                                                    "public, max-age=86400"
                                                    "public, max-age=300")
                (ht:header-out "X-Content-Type-Options") "nosniff"
                ;; Images only; neuters anything active in an SVG.
                (ht:header-out "Content-Security-Policy") "default-src 'none'; style-src 'unsafe-inline'")
          data))))

(defparameter *max-count-keys* 100)

;;; JSON: JZON:STRINGIFY turns hash tables into objects and vectors into
;;; arrays. ALEXANDRIA:PLIST-HASH-TABLE is a handy way to write a small
;;; object inline.
;;;
;;; CORS: browsers forbid a script on blog.ryanfleck.ca from reading our
;;; responses unless we answer with Access-Control-Allow-Origin naming that
;;; origin. We echo the request's Origin only if it's one of the site's
;;; configured origins (plus Vary: Origin so caches keep per-origin copies).
(defun json-response (object &key (status 200))
  (setf (ht:content-type*) "application/json"
        (ht:return-code*) status)
  (jzon:stringify object))

(defun allow-site-cors (site)
  (let ((origin (ht:header-in* :origin)))
    (when (and origin (member origin (getf site :origins) :test #'string=))
      (setf (ht:header-out "Access-Control-Allow-Origin") origin
            (ht:header-out "Vary") "Origin"))))

(easy-routes:defroute api-counts ("/api/counts" :method :get) (&get site)
  ;; GET /api/counts?site=blog&page=<url>&page=<url>&id=<page-id>...
  ;; → {"<url or id as sent>": published-count, ...}
  (let ((site (and site (site-by-key site)))
        (requested (remove-duplicates
                    (loop for (name . value) in (ht:get-parameters*)
                          when (member name '("page" "id") :test #'string=)
                            collect (cons name value))
                    :test #'equal)))
    (cond ((or (null site) (not (getf site :enabled)))
           (json-response (alexandria:plist-hash-table '("error" "unknown site") :test #'equal)
                          :status 404))
          ((> (length requested) *max-count-keys*)
           (json-response (alexandria:plist-hash-table
                           (list "error" (format nil "at most ~d keys" *max-count-keys*))
                           :test #'equal)
                          :status 400))
          (t
           (allow-site-cors site)
           (setf (ht:header-out "Cache-Control") "public, max-age=60")
           ;; Map each requested value to its thread key: canonical URL for
           ;; pages on this site's origins, the id itself for valid page ids.
           (let* ((keyed (loop for (name . value) in requested
                               collect (cons value
                                             (if (string= name "page")
                                                 (let ((url (canonical-page-url value)))
                                                   (and url (site-allows-page-p site url) url))
                                                 (clean-page-id value)))))
                  (counts (thread-counts (getf site :id)
                                         (remove-duplicates (remove nil (mapcar #'cdr keyed))
                                                            :test #'string=)))
                  (result (make-hash-table :test #'equal)))
             (loop for (value . key) in keyed
                   do (setf (gethash value result) (if key (gethash key counts 0) 0)))
             (json-response result))))))

(easy-routes:defroute api-comments ("/api/comments" :method :get) (&get site page id)
  (setf (ht:content-type*) "application/json")
  (multiple-value-bind (site page-url page-id key) (resolve-thread site page id)
    (declare (ignore page-id))
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
            (loop for c in (page-comments (getf (thread-by-key (getf site :id) key) :id))
                  collect (alexandria:plist-hash-table
                           (list "id" (getf c :id) "author" (getf c :display-name)
                                 "body" (getf c :body) "created_at" (getf c :created-at))
                           :test #'equal))
            'vector))))))

;;; Used by Docker's HEALTHCHECK (via `rf-comments healthcheck`, main.lisp)
;;; and by humans with curl. It touches the database so a broken volume shows
;;; up as unhealthy.
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
