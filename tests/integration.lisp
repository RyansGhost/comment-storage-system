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
