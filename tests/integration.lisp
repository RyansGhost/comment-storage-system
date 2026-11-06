;;;; tests/integration.lisp — drive the real HTTP server end to end.
;;;;
;;;; A server is started on a random local port against a temporary
;;;; database, with emails captured in memory instead of sent.
;;;;
;;;; These tests talk to the server exactly as a browser would: over HTTP,
;;;; with Dexador as the client, a cookie jar per simulated person (alice,
;;;; bob, admin…), and an Origin header to pass the CSRF check. Asserting
;;;; on status codes, headers and HTML substrings keeps them independent of
;;;; implementation details, so internal refactors (like the route macros)
;;;; don't break them.
;;;;
;;;; Emails are captured (EMAIL-BACKEND :capture), and the tests "click"
;;;; links by pulling the token out of the captured email text.

(in-package #:rf-comments/tests)

(def-suite integration :in all)
(in-suite integration)

(defvar *base* nil)
(defparameter +page+ "https://blog.example.com/posts/hello/")

(defun temp-db-path ()
  (namestring (merge-pathnames (format nil "rf-comments-test-~a.db" (random-token 6))
                               (uiop:temporary-directory))))

;;; Each test gets a fresh server on a random port and a fresh database file.
;;; We build an APP-ACCEPTOR directly instead of calling RF-COMMENTS:START, so
;;; a development server already running in the same REPL (on *ACCEPTOR*) is
;;; left alone. Routes are global to easy-routes, so both acceptors serve
;;; the same handlers.
(defmacro with-test-server (() &body body)
  `(let* ((port (+ 20000 (random 20000 (make-random-state t))))
          (db (temp-db-path))
          (acceptor (make-instance 'rf-comments::app-acceptor
                                   :port port :address "127.0.0.1"
                                   :access-log-destination nil
                                   :message-log-destination nil)))
     (with-globals ((*base* (format nil "http://127.0.0.1:~d" port))
                    (rf-comments:*public-url* (format nil "http://127.0.0.1:~d" port))
                    (rf-comments:*email-backend* :capture)
                    (rf-comments:*captured-emails* '())
                    (rf-comments:*admin-password* "s3cret")
                    (rf-comments:*cookie-secure* nil)
                    (rf-comments:*trust-proxy* nil)
                    (rf-comments::*emails-per-hour* 5)
                    (hunchentoot:*hunchentoot-default-external-format*
                     (flex:make-external-format :utf-8 :eol-style :lf))
                    (hunchentoot:*default-content-type* "text/html; charset=utf-8"))
       (rf-comments::reset-rate-limits)
       (with-temp-db (db)
         (hunchentoot:start acceptor)
         (unwind-protect (progn ,@body)
           (hunchentoot:stop acceptor)
           (rf-comments::reset-rate-limits)
           (dolist (suffix '("" "-wal" "-shm"))
             (uiop:delete-file-if-exists (concatenate 'string db suffix))))))))

;;; Dexador options worth knowing:
;;;   :CONTENT alist      sent as an application/x-www-form-urlencoded form
;;;   :COOKIE-JAR jar     stores Set-Cookie responses, replays them later
;;;   :MAX-REDIRECTS 0    don't follow redirects: we want to *see* the 303
;;;                       and its Location
;;;   :PROXY NIL          ignore any HTTP(S)_PROXY in the environment
;;; Dexador signals on 4xx/5xx. We catch that and return the same three
;;; values, so a test can assert (= 403 status) like any other result.
(defun req (method path &key jar params (origin :self) headers)
  "Make a request without following redirects.
Returns (values body status headers-hash-table)."
  (let ((headers (append headers
                         (case origin
                           (:self `(("Origin" . ,*base*)))
                           ((nil) nil)
                           (t `(("Origin" . ,origin)))))))
    (handler-case
        (multiple-value-bind (body status hdrs)
            (dex:request (concatenate 'string *base* path)
                         :method method :content params :headers headers
                         :cookie-jar jar :max-redirects 0 :proxy nil
                         :force-string t :keep-alive nil)
          (values body status hdrs))
      (dex:http-request-failed (e)
        (values (dex:response-body e) (dex:response-status e) (dex:response-headers e))))))

(defun location (headers) (gethash "location" headers))

(defun thread-path (&key (site "blog") (page +page+))
  (format nil "/thread?site=~a&page=~a&title=Hello" site (quri:url-encode page)))

(defun last-email-token ()
  (let ((email (first rf-comments:*captured-emails*)))
    (and email (cl-ppcre:scan-to-strings "[0-9a-f]{64}" (getf email :text)))))

(defun has (needle haystack) (and haystack (search needle haystack) t))

(defun admin-jar ()
  (let ((jar (cl-cookie:make-cookie-jar)))
    (req :post "/admin/login" :jar jar :params '(("password" . "s3cret")))
    jar))

(defun make-blog-site (jar &rest extra)
  (req :post "/admin/sites" :jar jar
                            :params (append `(("key" . "blog") ("name" . "Blog")
                                              ("origins" . "https://blog.example.com")
                                              ("enabled" . "1"))
                                            extra)))

(defun post-comment (jar &key (name "Alice") (email "Alice@Example.com") (body "Hello")
                           (website "") (page +page+))
  (req :post "/thread/comment" :jar jar
                               :params `(("site" . "blog") ("page" . ,page) ("title" . "Hello")
                                         ("name" . ,name) ("email" . ,email) ("body" . ,body)
                                         ("website" . ,website))))

;;; ------------------------------------------------------------------

(test admin-auth-and-sites
  (with-test-server ()
    (multiple-value-bind (body status headers) (req :get "/admin")
      (declare (ignore body))
      (is (= 303 status))
      (is (has "/admin/login" (location headers))))
    (is (= 401 (nth-value 1 (req :post "/admin/login" :params '(("password" . "wrong"))))))
    (is (= 403 (nth-value 1 (req :post "/admin/login" :origin "https://evil.example.com"
                                                      :params '(("password" . "s3cret"))))))
    (let ((jar (admin-jar)))
      (multiple-value-bind (body status headers) (make-blog-site jar)
        (declare (ignore body))
        (is (= 303 status))
        (is (has "/admin/sites/1" (location headers))))
      ;; Duplicate keys and bad origins are rejected.
      (is (= 422 (nth-value 1 (make-blog-site jar))))
      (is (= 422 (nth-value 1 (req :post "/admin/sites" :jar jar
                                   :params '(("key" . "x") ("name" . "X")
                                             ("origins" . "not a url"))))))
      (let ((page (req :get "/admin/sites/1" :jar jar)))
        (is (has "data-site=&quot;blog&quot;" page))
        (is (has "https://blog.example.com" page)))
      (is (has "Blog" (req :get "/admin" :jar jar)))
      ;; Logout ends the session.
      (req :post "/admin/logout" :jar jar)
      (is (= 303 (nth-value 1 (req :get "/admin" :jar jar)))))))

(test admin-disabled-without-password
  (with-test-server ()
    (with-globals ((rf-comments:*admin-password* nil))
      (is (= 404 (nth-value 1 (req :get "/admin/login"))))
      (is (= 404 (nth-value 1 (req :get "/admin")))))))

(test thread-access-rules
  (with-test-server ()
    (make-blog-site (admin-jar))
    (multiple-value-bind (body status headers) (req :get (thread-path))
      (is (= 200 status))
      (is (has "0 comments" body))
      (is (has "frame-ancestors 'self' https://blog.example.com"
               (gethash "content-security-policy" headers))))
    (is (has "not enabled for this domain"
             (req :get (thread-path :page "https://evil.example.com/x"))))
    (is (has "not enabled for this site" (req :get (thread-path :site "nope"))))
    (is (has "not enabled for this site" (req :get "/thread")))))

(test comment-verify-login-profile-flow
  (with-test-server ()
    (let ((admin (admin-jar))
          (alice (cl-cookie:make-cookie-jar))
          (anon (cl-cookie:make-cookie-jar)))
      (make-blog-site admin)
      ;; CSRF: posts must come from our own origin.
      (is (= 403 (nth-value 1 (req :post "/thread/comment" :origin nil
                                   :params `(("site" . "blog") ("page" . ,+page+))))))
      ;; Anonymous comment → pending + verification email.
      (multiple-value-bind (body status headers)
          (post-comment alice :body (format nil "Hello <b>world</b>~%~%Second para"))
        (declare (ignore body))
        (is (= 303 status))
        (is (has "notice=check-email" (location headers))))
      (is (= 1 (length rf-comments:*captured-emails*)))
      (is (string= "alice@example.com" (getf (first rf-comments:*captured-emails*) :to)))
      (is (has "0 comments" (req :get (thread-path) :jar anon)))
      (is (not (has "Second para" (req :get (thread-path) :jar anon))))
      (let ((row (rf-comments:query-one "SELECT * FROM comments")))
        (is (string= "pending" (getf row :status)))
        (is (string= +page+ (getf row :page-url))))
      ;; GET /verify only shows a button; it must not consume the token.
      (let ((token (last-email-token)))
        (multiple-value-bind (body status headers)
            (req :get (format nil "/verify?token=~a" token))
          (is (= 200 status))
          (is (has "Publish my comment" body))
          ;; Browsers apply form-action to the post-submit redirect, and send
          ;; "Origin: null" under no-referrer; both broke this flow once.
          (is (has "form-action 'self' https://blog.example.com"
                   (gethash "content-security-policy" headers)))
          (is (not (has "no-referrer" (gethash "referrer-policy" headers)))))
        (is (has "Publish my comment" (req :get (format nil "/verify?token=~a" token))))
        (multiple-value-bind (body status headers)
            (req :post "/verify" :jar alice :params `(("token" . ,token)))
          (declare (ignore body))
          (is (= 303 status))
          (is (string= (format nil "~a#rf-comments" +page+) (location headers))))
        ;; Single use.
        (is (= 410 (nth-value 1 (req :post "/verify" :params `(("token" . ,token)))))))
      (let ((thread (req :get (thread-path) :jar anon)))
        (is (has "1 comment" thread))
        (is (has "Alice" thread))
        (is (has "&lt;b&gt;world&lt;/b&gt;" thread))
        (is (not (has "<b>world" thread))))
      ;; Alice is now signed in: her next comment is published immediately.
      (is (has "Commenting as" (req :get (thread-path) :jar alice)))
      (multiple-value-bind (body status headers) (post-comment alice :body "Second!")
        (declare (ignore body))
        (is (= 303 status))
        (is (has "notice=posted" (location headers))))
      (is (= 1 (length rf-comments:*captured-emails*)))
      (is (has "2 comments" (req :get (thread-path) :jar anon)))
      ;; Profile.
      (let ((me (req :get "/me" :jar alice)))
        (is (has "Hi, Alice" me))
        (is (has "Second!" me))
        (is (has "alice@example.com" me)))
      (req :post "/me/name" :jar alice :params '(("name" . "Alice B")))
      (is (has "Hi, Alice B" (req :get "/me" :jar alice)))
      ;; Someone else using Alice's email can't publish or rename her.
      (post-comment anon :name "Mallory" :body "spoofed")
      (is (has "2 comments" (req :get (thread-path) :jar anon)))
      (is (not (has "spoofed" (req :get (thread-path) :jar anon))))
      (is (has "Hi, Alice B" (req :get "/me" :jar alice)))
      ;; Admin moderation: hide one comment.
      (let ((id (getf (rf-comments:query-one
                       "SELECT id FROM comments WHERE body = 'Second!'") :id)))
        (req :post (format nil "/admin/comments/~d/hide" id) :jar admin)
        (is (has "1 comment" (req :get (thread-path) :jar anon)))
        (req :post (format nil "/admin/comments/~d/publish" id) :jar admin)
        (is (has "2 comments" (req :get (thread-path) :jar anon)))
        ;; Users delete only their own comments.
        (let ((spoof (getf (rf-comments:query-one
                            "SELECT id FROM comments WHERE body = 'spoofed'") :id))
              (bob (cl-cookie:make-cookie-jar)))
          (declare (ignore spoof))
          (post-comment bob :name "Bob" :email "bob@example.com" :body "bob here")
          (req :post "/verify" :jar bob :params `(("token" . ,(last-email-token))))
          (req :post (format nil "/me/comments/~d/delete" id) :jar bob)
          (is (rf-comments:query-one "SELECT id FROM comments WHERE id = ?" id))
          (req :post (format nil "/me/comments/~d/delete" id) :jar alice)
          (is (null (rf-comments:query-one "SELECT id FROM comments WHERE id = ?" id)))))
      ;; Logout.
      (multiple-value-bind (body status headers)
          (req :post "/logout" :jar alice :params '(("return" . "/me")))
        (declare (ignore body))
        (is (= 303 status))
        (is (has "/me" (location headers))))
      (is (= 303 (nth-value 1 (req :get "/me" :jar alice)))))))

(test magic-link-login
  (with-test-server ()
    (make-blog-site (admin-jar))
    (post-comment (cl-cookie:make-cookie-jar) :name "Carol" :email "carol@example.com")
    (setf rf-comments:*captured-emails* '())
    ;; Unknown addresses get the same answer but no email.
    (is (has "sign-in link is on its way"
             (req :post "/login" :params '(("email" . "nobody@example.com")))))
    (is (null rf-comments:*captured-emails*))
    (is (= 422 (nth-value 1 (req :post "/login" :params '(("email" . "bad"))))))
    (req :post "/login" :params '(("email" . "Carol@example.com")))
    (is (= 1 (length rf-comments:*captured-emails*)))
    (let ((token (last-email-token))
          (jar (cl-cookie:make-cookie-jar)))
      (is (has "Sign in" (req :get (format nil "/login/callback?token=~a" token))))
      (multiple-value-bind (body status headers)
          (req :post "/login/callback" :jar jar :params `(("token" . ,token)))
        (declare (ignore body))
        (is (= 303 status))
        (is (has "/me" (location headers))))
      (let ((me (req :get "/me" :jar jar)))
        (is (has "Hi, Carol" me))
        (is (has "pending" me)))
      (is (= 410 (nth-value 1 (req :post "/login/callback" :params `(("token" . ,token)))))))))

(test spam-defences
  (with-test-server ()
    (make-blog-site (admin-jar))
    ;; Honeypot: looks like success, stores nothing, sends nothing.
    (multiple-value-bind (body status headers) (post-comment nil :website "http://spam")
      (declare (ignore body))
      (is (= 303 status))
      (is (has "check-email" (location headers))))
    (is (null (rf-comments:query "SELECT * FROM comments")))
    (is (null rf-comments:*captured-emails*))
    ;; Validation errors re-render the form with the input preserved.
    (multiple-value-bind (body status) (post-comment nil :name "Dave" :body "   ")
      (is (= 422 status))
      (is (has "Your comment is empty" body))
      (is (has "value=Dave" body)))
    (is (= 422 (nth-value 1 (post-comment nil :email "not-an-email"))))
    ;; Per-address email limit.
    (with-globals ((rf-comments::*emails-per-hour* 1))
      (is (has "check-email" (location (nth-value 2 (post-comment nil :email "e@example.com")))))
      (is (has "email-limit" (location (nth-value 2 (post-comment nil :email "e@example.com"))))))
    ;; Per-IP comment rate limit.
    (with-globals ((rf-comments::*comments-per-window* 0))
      (is (= 429 (nth-value 1 (post-comment nil)))))))

(test themes-and-disabling
  (with-test-server ()
    (let ((admin (admin-jar)))
      (make-blog-site admin '("theme_accent" . "#ff0000") '("theme_scheme" . "dark")
                      '("theme_custom_css" . ".rf{color:red}</style><script>x()</script>"))
      (let ((thread (req :get (thread-path))))
        (is (has "--rf-accent:#ff0000" thread))
        (is (has "color-scheme:dark" thread))
        (is (has ".rf{color:red}" thread))
        ;; Custom CSS can't close the <style> element (so the <script> stays inert text).
        (is (not (has "</style><script>x()" thread)))
        (is (has "<\\/style><script>x()<\\/script>" thread)))
      ;; Disable the site: the thread goes inert.
      (req :post "/admin/sites/1" :jar admin
                                  :params '(("key" . "blog") ("name" . "Blog")
                                            ("origins" . "https://blog.example.com")))
      (is (has "not enabled for this site" (req :get (thread-path)))))))

(test assets-api-and-health
  (with-test-server ()
    (make-blog-site (admin-jar))
    (multiple-value-bind (body status headers) (req :get "/embed.js")
      (is (= 200 status))
      (is (has "javascript" (gethash "content-type" headers)))
      (is (has "rf-comments:height" body)))
    (is (has "postMessage" (req :get "/static/thread.js")))
    (is (string= "ok" (req :get "/healthz")))
    (let ((jar (cl-cookie:make-cookie-jar)))
      (post-comment jar :body "api body")
      (req :post "/verify" :jar jar :params `(("token" . ,(last-email-token)))))
    (multiple-value-bind (body status headers)
        (req :get (format nil "/api/comments?site=blog&page=~a" (quri:url-encode +page+))
             :origin "https://blog.example.com")
      (is (= 200 status))
      (is (string= "https://blog.example.com"
                   (gethash "access-control-allow-origin" headers)))
      (let ((json (com.inuoe.jzon:parse body)))
        (is (= 1 (length json)))
        (is (string= "api body" (gethash "body" (aref json 0))))
        (is (string= "Alice" (gethash "author" (aref json 0))))))
    (is (= 404 (nth-value 1 (req :get "/api/comments?site=nope&page=x"))))))

;;; ------------------------------------------------------------------
;;; Route DSL guarantees (src/routes.lisp)

(test every-post-route-is-a-csrf-protected-action
  ;; Introspect easy-routes' registry: no POST route may skip @SAME-ORIGIN,
  ;; i.e. every POST handler must be declared with DEFACTION.
  (let ((posts '()))
    (maphash (lambda (name route)
               (when (eq :post (easy-routes::required-method route))
                 (push name posts)
                 (is (eq 'rf-comments::@same-origin
                         (first (easy-routes::route-decorators route)))
                     "POST route ~a does not run @same-origin first" name)))
             easy-routes::*routes*)
    (is (= (length posts) (length rf-comments::*actions*)))
    (is (>= (length posts) 13))))

(test every-action-rejects-cross-site-posts
  (with-test-server ()
    (dolist (template rf-comments::*actions*)
      (let ((path (cl-ppcre:regex-replace-all ":[a-z-]+" template "1")))
        (is (= 403 (nth-value 1 (req :post path :origin nil)))
            "~a accepted a POST without Origin" path)
        (is (= 403 (nth-value 1 (req :post path :origin "https://evil.example.com")))
            "~a accepted a cross-site POST" path)
        ;; Fetch Metadata wins even when Origin looks right.
        (dolist (site '("cross-site" "same-site"))
          (is (= 403 (nth-value 1 (req :post path :headers `(("Sec-Fetch-Site" . ,site)))))
              "~a accepted a POST with Sec-Fetch-Site: ~a" path site))))))

(test fetch-metadata-and-null-origin
  ;; OWASP CSRF cheat sheet: Sec-Fetch-Site is the primary signal for modern
  ;; browsers, Origin/Referer the mandatory fallback, and "Origin: null" is
  ;; never evidence of a same-origin request.
  (with-test-server ()
    (let ((params '(("email" . "nobody@example.com")))
          (our-page (format nil "~a/login" *base*)))
      ;; What a modern browser sends for our own form.
      (is (= 200 (nth-value 1 (req :post "/login" :params params
                                                  :headers '(("Sec-Fetch-Site" . "same-origin"))))))
      (is (= 403 (nth-value 1 (req :post "/login" :params params
                                                  :headers '(("Sec-Fetch-Site" . "none"))))))
      ;; A present Origin must match: null fails even with our own Referer.
      (is (= 403 (nth-value 1 (req :post "/login" :params params :origin "null"
                                                  :headers `(("Referer" . ,our-page))))))
      ;; Legacy fallback: no Fetch Metadata, no Origin, our own Referer.
      (is (= 200 (nth-value 1 (req :post "/login" :params params :origin nil
                                                  :headers `(("Referer" . ,our-page))))))
      ;; Nothing to go on at all.
      (is (= 403 (nth-value 1 (req :post "/login" :params params :origin nil)))))))

;;; ------------------------------------------------------------------
;;; Observers (src/events.lisp)

(defun emails-to (address)
  (remove address rf-comments:*captured-emails*
          :key (lambda (e) (getf e :to)) :test-not #'string=))

(defun log-actions ()
  (mapcar (lambda (row) (list (getf row :action) (getf row :actor)))
          (reverse (rf-comments::recent-moderation 100))))

(test observers-notify-admin-and-log-moderation
  (with-test-server ()
    (with-globals ((rf-comments::*admin-email* "admin@example.com"))
      (let ((admin (admin-jar))
            (alice (cl-cookie:make-cookie-jar)))
        (make-blog-site admin)
        ;; Pending comments don't notify the admin.
        (post-comment alice :body "first")
        (is (null (emails-to "admin@example.com")))
        ;; Publishing through the verify link does.
        (req :post "/verify" :jar alice :params `(("token" . ,(last-email-token))))
        (is (= 1 (length (emails-to "admin@example.com"))))
        (let ((mail (first (emails-to "admin@example.com"))))
          (is (has "New comment by Alice" (getf mail :subject)))
          (is (has "first" (getf mail :text)))
          (is (has "/admin?status=published" (getf mail :text))))
        ;; A signed-in comment publishes (and notifies) immediately.
        (post-comment alice :body "second")
        (is (= 2 (length (emails-to "admin@example.com"))))
        ;; Admin moderation is logged but never emails the admin.
        (let ((id (getf (rf-comments:query-one "SELECT id FROM comments WHERE body = 'second'") :id))
              (first-id (getf (rf-comments:query-one "SELECT id FROM comments WHERE body = 'first'") :id)))
          (req :post (format nil "/admin/comments/~d/hide" id) :jar admin)
          (req :post (format nil "/admin/comments/~d/publish" id) :jar admin)
          (req :post (format nil "/me/comments/~d/delete" first-id) :jar alice)
          (req :post (format nil "/admin/comments/~d/delete" id) :jar admin))
        (is (= 2 (length (emails-to "admin@example.com"))))
        (is (equal '(("publish" "author") ("publish" "author") ("hide" "admin")
                     ("publish" "admin") ("delete" "author") ("delete" "admin"))
                   (log-actions)))
        ;; The log survives deletion and shows on the dashboard.
        (let ((dash (req :get "/admin" :jar admin)))
          (is (has "Activity" dash))
          (is (has "Alice on https://blog.example.com/posts/hello/: second" dash)))))))

(test no-admin-email-when-unset
  (with-test-server ()
    (with-globals ((rf-comments::*admin-email* nil))
      (let ((jar (cl-cookie:make-cookie-jar)))
        (make-blog-site (admin-jar))
        (post-comment jar)
        (req :post "/verify" :jar jar :params `(("token" . ,(last-email-token))))
        ;; Only the verification email was sent.
        (is (= 1 (length rf-comments:*captured-emails*)))
        (is (has "1 comment" (req :get (thread-path))))))))

(test failing-observer-does-not-break-requests
  (with-test-server ()
    (let ((method (defmethod rf-comments::publish-comment :after ((comment cons) by)
                    (declare (ignore by))
                    (error "observer exploded"))))
      (unwind-protect
           (let ((jar (cl-cookie:make-cookie-jar))
                 (*error-output* (make-broadcast-stream)))
             (make-blog-site (admin-jar))
             (post-comment jar)
             (is (= 303 (nth-value 1 (req :post "/verify" :jar jar
                                                          :params `(("token" . ,(last-email-token)))))))
             ;; The primary method and the other observers still ran.
             (is (has "1 comment" (req :get (thread-path))))
             (is (equal '(("publish" "author")) (log-actions))))
        (remove-method #'rf-comments::publish-comment method)))))

;;; ------------------------------------------------------------------
;;; Stable thread ids

(defun id-thread-path (id page)
  (format nil "/thread?site=blog&id=~a&page=~a" id (quri:url-encode page)))

(test page-id-threads-survive-url-changes
  (with-test-server ()
    (make-blog-site (admin-jar))
    (let ((alice (cl-cookie:make-cookie-jar))
          (old "https://blog.example.com/2026/old-slug/")
          (new "https://blog.example.com/2026/new-slug/"))
      ;; Comment while the post lives at its old URL.
      (req :post "/thread/comment" :jar alice
                                   :params `(("site" . "blog") ("page" . ,old) ("id" . "post-42")
                                             ("name" . "Alice") ("email" . "a@example.com")
                                             ("body" . "kept across moves")))
      (req :post "/verify" :jar alice :params `(("token" . ,(last-email-token))))
      ;; The post moves: same data-page-id, new URL. The thread follows it.
      (let ((thread (req :get (id-thread-path "post-42" new))))
        (is (has "1 comment" thread))
        (is (has "kept across moves" thread))
        (is (has "name=id value=post-42" thread)))
      (is (string= new (getf (rf-comments::thread-by-key 1 "post-42") :url)))
      ;; The old URL without an id is a different (empty) thread.
      (is (has "0 comments" (req :get (thread-path :page old))))
      ;; Profile links point at the page's current URL.
      (is (has new (req :get "/me" :jar alice)))
      ;; JSON API by id.
      (let ((json (com.inuoe.jzon:parse
                   (req :get (format nil "/api/comments?site=blog&id=post-42&page=~a"
                                     (quri:url-encode new))))))
        (is (= 1 (length json))))
      ;; Invalid ids are refused.
      (is (has "comment id is invalid" (req :get (id-thread-path "bad%20id" new)))))))

(test admin-move-and-merge-threads
  (with-test-server ()
    (let ((admin (admin-jar))
          (alice (cl-cookie:make-cookie-jar))
          (a "https://blog.example.com/a/")
          (b "https://blog.example.com/b/"))
      (make-blog-site admin)
      ;; Two URL-keyed threads with one comment each.
      (post-comment alice :page a :body "on a")
      (req :post "/verify" :jar alice :params `(("token" . ,(last-email-token))))
      (post-comment alice :page b :body "on b")
      (let ((ta (getf (rf-comments::thread-by-key 1 a) :id))
            (tb (getf (rf-comments::thread-by-key 1 b) :id)))
        (is (has a (req :get "/admin/sites/1" :jar admin)))
        ;; Re-key A to a stable id: an embed with data-page-id="post-7" now shows it.
        (is (= 303 (nth-value 1 (req :post (format nil "/admin/threads/~d/move" ta) :jar admin
                                     :params `(("key" . "post-7") ("url" . ,a))))))
        (is (has "on a" (req :get (id-thread-path "post-7" a))))
        ;; Moving B onto the same key merges the two threads.
        (req :post (format nil "/admin/threads/~d/move" tb) :jar admin
                                                            :params `(("key" . "post-7") ("url" . ,b)))
        (let ((thread (req :get (id-thread-path "post-7" b))))
          (is (has "2 comments" thread))
          (is (has "on a" thread))
          (is (has "on b" thread)))
        (is (null (rf-comments::thread-by-id tb)))
        ;; URLs outside the site's origins are rejected.
        (is (= 422 (nth-value 1 (req :post (format nil "/admin/threads/~d/move" ta) :jar admin
                                     :params '(("key" . "x") ("url" . "https://evil.example.com/"))))))))))

;;; ------------------------------------------------------------------
;;; Counts API and admin stats

(defun counts (query &key (origin :self))
  (multiple-value-bind (body status headers)
      (req :get (format nil "/api/counts?~a" query) :origin origin)
    (values (and (= status 200) (com.inuoe.jzon:parse body)) status headers)))

(test counts-api
  (with-test-server ()
    (let ((admin (admin-jar))
          (alice (cl-cookie:make-cookie-jar))
          (a "https://blog.example.com/a/")
          (b "https://blog.example.com/b/"))
      (make-blog-site admin)
      ;; Two published comments on A, one pending on B, one published on id post-1.
      (post-comment alice :page a :body "a1")
      (req :post "/verify" :jar alice :params `(("token" . ,(last-email-token))))
      (post-comment alice :page a :body "a2")
      (post-comment nil :page b :name "Bob" :email "bob@example.com" :body "b1")
      (req :post "/thread/comment" :jar alice
                                   :params `(("site" . "blog") ("page" . ,a) ("id" . "post-1")
                                             ("body" . "id comment")))
      (multiple-value-bind (json status headers)
          (counts (format nil "site=blog&page=~a&page=~a&page=~a&page=~a&id=post-1&id=nope"
                          (quri:url-encode a)
                          (quri:url-encode (concatenate 'string a "index.html?utm=x"))
                          (quri:url-encode b)
                          (quri:url-encode "https://evil.example.com/a/"))
                  :origin "https://blog.example.com")
        (is (= 200 status))
        (is (= 2 (gethash a json)))
        ;; Keys come back exactly as sent, even when they canonicalise.
        (is (= 2 (gethash (concatenate 'string a "index.html?utm=x") json)))
        (is (= 0 (gethash b json)))          ; only a pending comment
        (is (= 0 (gethash "https://evil.example.com/a/" json)))
        (is (= 1 (gethash "post-1" json)))
        (is (= 0 (gethash "nope" json)))
        (is (string= "https://blog.example.com" (gethash "access-control-allow-origin" headers)))
        (is (has "max-age=60" (gethash "cache-control" headers))))
      ;; No CORS for foreign origins.
      (is (null (gethash "access-control-allow-origin"
                         (nth-value 2 (counts "site=blog&id=post-1"
                                              :origin "https://evil.example.com")))))
      ;; Caps and errors.
      (is (= 400 (nth-value 1 (counts (format nil "site=blog~{&id=k~d~}"
                                              (loop for i below 101 collect i))))))
      (is (= 404 (nth-value 1 (counts "site=nope&id=x")))))))

(test admin-stats
  (with-test-server ()
    (let ((admin (admin-jar))
          (alice (cl-cookie:make-cookie-jar)))
      (make-blog-site admin)
      (post-comment alice :body "one")
      (req :post "/verify" :jar alice :params `(("token" . ,(last-email-token))))
      (post-comment alice :body "two")
      (post-comment nil :name "Bob" :email "bob@example.com" :body "pending")
      (let ((dash (req :get "/admin" :jar admin)))
        (is (has "Stats" dash))
        (is (has "Comments per day" dash))
        (is (has (subseq (iso-time) 0 10) dash))
        (is (has "width:100.0%" dash))
        (is (has "Most-commented threads" dash))
        (is (has " · blog · 2" dash)))
      (let ((row (first (rf-comments::site-status-counts))))
        (is (= 2 (getf row :published)))
        (is (= 1 (getf row :pending)))
        (is (= 0 (getf row :hidden)))))))

(test count-js-is-served
  (with-test-server ()
    (multiple-value-bind (body status headers) (req :get "/count.js")
      (is (= 200 status))
      (is (has "javascript" (gethash "content-type" headers)))
      (is (has "/api/counts?" body)))))

;;; ------------------------------------------------------------------
;;; Opt-in live REPL (src/repl.lisp)

(defun slynk-packet (string)
  (format nil "~6,'0x~a" (length string) string))

(defun slynk-exchange (port secret)
  "Connect, authenticate with SECRET, ask for connection-info. Returns
everything the server sent back within a couple of seconds."
  (let ((socket (usocket:socket-connect "127.0.0.1" port :element-type 'character)))
    (unwind-protect
         (let ((stream (usocket:socket-stream socket)))
           ;; Slynk compares the raw first packet with the secret (as SLY sends it).
           (write-string (slynk-packet secret) stream)
           (write-string (slynk-packet
                          "(:emacs-rex (slynk:connection-info) \"COMMON-LISP-USER\" t 1)")
                         stream)
           (force-output stream)
           (with-output-to-string (out)
             (loop with deadline = (+ (get-internal-real-time)
                                      (* 3 internal-time-units-per-second))
                   while (< (get-internal-real-time) deadline)
                   do (handler-case
                          (if (listen stream)
                              (write-char (read-char stream) out)
                              (sleep 0.05))
                        (error () (return))))))
      (usocket:socket-close socket))))

(test repl-is-off-by-default-and-fails-closed
  (let ((*error-output* (make-broadcast-stream)))
    (is (null (rf-comments::maybe-start-slynk :port nil)))
    (is (null (rf-comments::maybe-start-slynk :port 4999 :secret nil)))
    (is (null (rf-comments::maybe-start-slynk :port 4999 :secret "too-short")))))

(test repl-requires-the-secret
  (let* ((port (+ 40000 (random 10000 (make-random-state t))))
         (secret "a-long-enough-test-secret")
         (old-home (uiop:getenv "HOME"))
         (*error-output* (make-broadcast-stream)))
    (unwind-protect
         (progn
           (is (eql port (rf-comments::maybe-start-slynk :port port :interface "127.0.0.1"
                                                         :secret secret)))
           (is (not (has ":ok" (slynk-exchange port "wrong-secret"))))
           (is (has "(:return (:ok" (slynk-exchange port secret))))
      (ignore-errors (uiop:symbol-call :slynk :stop-server port))
      (when old-home (sb-posix:setenv "HOME" old-home 1)))))

;;; ------------------------------------------------------------------
;;; Gravatar avatars (src/avatars.lisp)

(defparameter +png+ (coerce #(137 80 78 71 13 10 26 10 1 2 3) '(vector (unsigned-byte 8))))

(defun avatar-src (html)
  (cl-ppcre:register-groups-bind (path) ("<img class=rf-avatar src=\"?(/avatar/[0-9a-f]+)" html)
    path))

(defun body-octets (path)
  (multiple-value-bind (body status headers)
      (dex:request (concatenate 'string *base* path) :method :get :force-binary t
                                                     :proxy nil :keep-alive nil)
    (values body status headers)))

(test gravatar-avatars-are-proxied
  (with-test-server ()
    (let* ((fetched '())
           (alice-hash (sha256-hex "alice@example.com")))
      (with-globals ((rf-comments::*avatars* :gravatar)
                     (rf-comments::*avatar-fetcher*
                      (lambda (url) (push url fetched) (values +png+ "image/png"))))
        (rf-comments::reset-avatar-cache)
        (let ((jar (cl-cookie:make-cookie-jar)))
          (make-blog-site (admin-jar))
          (post-comment jar :email "Alice@Example.com")
          (req :post "/verify" :jar jar :params `(("token" . ,(last-email-token)))))
        (let* ((thread (req :get (thread-path)))
               (src (avatar-src thread)))
          (is (stringp src))
          ;; The page never reveals the email or its Gravatar hash.
          (is (not (has alice-hash thread)))
          (is (not (has "alice@example.com" thread)))
          (is (not (has "gravatar.com/avatar" thread)))
          ;; Attribution note at the bottom of the comments section.
          (is (has "Profile images are provided by" thread))
          (is (has "href=\"https://gravatar.com\"" thread))
          ;; The proxy serves Gravatar's image, fetched by hash, then cached.
          (multiple-value-bind (body status headers) (body-octets src)
            (is (= 200 status))
            (is (equalp +png+ body))
            (is (string= "image/png" (gethash "content-type" headers)))
            (is (has "max-age=86400" (gethash "cache-control" headers)))
            (is (has "default-src 'none'" (gethash "content-security-policy" headers))))
          (body-octets src)
          (is (= 1 (length fetched)))
          (is (has alice-hash (first fetched)))
          (is (has "d=identicon" (first fetched)))
          ;; Unknown keys are 404s.
          (is (= 404 (nth-value 1 (req :get "/avatar/0123456789abcdef0123")))))))))

(test gravatar-failures-fall-back
  (with-test-server ()
    (with-globals ((rf-comments::*avatars* :gravatar)
                   (rf-comments::*avatar-fetcher*
                    (lambda (url) (declare (ignore url)) (error "network down"))))
      (rf-comments::reset-avatar-cache)
      (let ((jar (cl-cookie:make-cookie-jar))
            (*error-output* (make-broadcast-stream)))
        (make-blog-site (admin-jar))
        (post-comment jar :name "zoë")
        (req :post "/verify" :jar jar :params `(("token" . ,(last-email-token))))
        (multiple-value-bind (body status headers) (req :get (avatar-src (req :get (thread-path))))
          (is (= 200 status))
          (is (has "image/svg+xml" (gethash "content-type" headers)))
          (is (has "max-age=300" (gethash "cache-control" headers)))
          (is (has ">Z</text>" body))))
      ;; An upstream SVG (could carry script) is refused the same way.
      (with-globals ((rf-comments::*avatar-fetcher*
                      (lambda (url) (declare (ignore url))
                        (values (babel:string-to-octets "<svg/>") "image/svg+xml"))))
        (rf-comments::reset-avatar-cache)
        (let ((*error-output* (make-broadcast-stream)))
          (is (has ">Z</text>" (req :get (avatar-src (req :get (thread-path)))))))))))

(test avatars-can-be-turned-off
  (with-test-server ()
    (with-globals ((rf-comments::*avatars* :off))
      (let ((jar (cl-cookie:make-cookie-jar)))
        (make-blog-site (admin-jar))
        (post-comment jar)
        (req :post "/verify" :jar jar :params `(("token" . ,(last-email-token))))
        (let ((thread (req :get (thread-path))))
          (is (has "1 comment" thread))
          (is (null (avatar-src thread)))
          (is (not (has "Gravatar" thread))))
        (let ((key (getf (rf-comments:query-one "SELECT avatar_key FROM users") :avatar-key)))
          (is (= 404 (nth-value 1 (req :get (format nil "/avatar/~a" key))))))))))
