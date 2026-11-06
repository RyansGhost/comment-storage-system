;;;; tests/integration.lisp — drive the real HTTP server end to end.
;;;;
;;;; A server is started on a random local port against a temporary
;;;; database, with emails captured in memory instead of sent.

(in-package #:rf-comments/tests)

(def-suite integration :in all)
(in-suite integration)

(defvar *base* nil)
(defparameter +page+ "https://blog.example.com/posts/hello/")

(defun temp-db-path ()
  (namestring (merge-pathnames (format nil "rf-comments-test-~a.db" (random-token 6))
                               (uiop:temporary-directory))))

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
            "~a accepted a cross-site POST" path)))))

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
