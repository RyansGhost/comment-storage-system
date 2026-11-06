;;;; tests/unit.lisp — pure functions and the data model.

(in-package #:rf-comments/tests)

(def-suite unit :in all)
(in-suite unit)

(test iso-time-format
  (is (string= "1970-01-01T00:00:00Z" (iso-time (encode-universal-time 0 0 0 1 1 1970 0))))
  (is (string= "2026-11-06T15:41:09Z" (iso-time (encode-universal-time 9 41 15 6 11 2026 0))))
  (is (string= "Nov 6, 2026" (rf-comments::human-date "2026-11-06T15:41:09Z"))))

(test canonical-page-urls
  (is (string= "https://blog.ryanfleck.ca/posts/x/"
               (canonical-page-url "https://Blog.RyanFleck.ca/posts/x/index.html?utm=1#top")))
  (is (string= "https://blog.ryanfleck.ca/" (canonical-page-url "https://blog.ryanfleck.ca")))
  (is (string= "https://blog.ryanfleck.ca/a" (canonical-page-url "https://blog.ryanfleck.ca:443/a")))
  (is (string= "http://localhost:8000/a" (canonical-page-url "http://localhost:8000/a?b")))
  (is (null (canonical-page-url "javascript:alert(1)")))
  (is (null (canonical-page-url "ftp://example.com/x")))
  (is (null (canonical-page-url "/relative/path")))
  (is (null (canonical-page-url nil))))

(test origins
  (is (string= "https://a.example.com" (url-origin "https://A.example.com/x/y?z")))
  (is (string= "http://localhost:8080" (url-origin "http://localhost:8080/")))
  (multiple-value-bind (ok bad)
      (parse-origins "https://a.example.com
https://b.example.com/, https://a.example.com  not-a-url")
    (is (equal '("https://a.example.com" "https://b.example.com") ok))
    (is (equal '("not-a-url") bad))))

(test email-and-name-validation
  (is (string= "alice@example.com" (normalize-email "  Alice@Example.COM ")))
  (is (null (normalize-email "nope")))
  (is (null (normalize-email "a@b")))
  (is (null (normalize-email "a b@example.com")))
  (is (null (normalize-email "")))
  (is (string= "Alice B" (rf-comments::clean-display-name "  Alice
   B ")))
  (is (null (rf-comments::clean-display-name "   ")))
  (is (null (rf-comments::clean-display-name (make-string 61 :initial-element #\a)))))

(test comment-bodies
  (is (string= (format nil "a~%b") (rf-comments::clean-body (format nil "  a~C~Cb  " #\Return #\Newline))))
  (is (null (rf-comments::clean-body "   ")))
  (is (null (rf-comments::clean-body (make-string 5001 :initial-element #\x))))
  (is (equal '(("one" "two") ("three"))
             (render-body (format nil "one~%two~%~%  ~%three")))))

(test html-escaping
  (let ((html (let ((*print-pretty* nil))
                (spinneret:with-html-string
                  (rf-comments::comment-body-html "<script>alert(1)</script> & co")))))
    (is (search "&lt;script&gt;" html))
    (is (not (search "<script>" html)))))

(test local-paths
  (is (rf-comments::local-path-p "/me"))
  (is (rf-comments::local-path-p "/thread?site=a&page=b"))
  (is (not (rf-comments::local-path-p "//evil.example.com")))
  (is (not (rf-comments::local-path-p "https://evil.example.com")))
  (is (not (rf-comments::local-path-p "/\\evil.example.com")))
  (is (not (rf-comments::local-path-p nil))))

(test rate-limiter
  (rf-comments::reset-rate-limits)
  (is (not (rf-comments::rate-limited-p :k 2 60)))
  (is (not (rf-comments::rate-limited-p :k 2 60)))
  (is (rf-comments::rate-limited-p :k 2 60))
  (is (not (rf-comments::rate-limited-p :other 2 60)))
  (rf-comments::reset-rate-limits))

(test crypto-helpers
  (is (string= "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" (sha256-hex "")))
  (is (= 64 (length (random-token))))
  (is (string/= (random-token) (random-token)))
  (is (rf-comments::constant-time-string= "secret" "secret"))
  (is (not (rf-comments::constant-time-string= "secret" "secreT")))
  (is (not (rf-comments::constant-time-string= nil "secret"))))

(test theme-css-is-contained
  (let* ((theme (make-hash-table :test #'equal))
         (site (list :theme theme)))
    (setf (gethash "accent" theme) "red;} body{display:none"
          (gethash "scheme" theme) "dark"
          (gethash "custom_css" theme) ".x{color:red}</style><script>alert(1)</script>")
    (let ((css (rf-comments::theme-css site)))
      (is (search "--rf-accent:red body" css))
      (is (not (search "</style>" css)))
      (is (search "color-scheme:dark" css)))))

(test schema-and-model
  (with-temp-db ()
    (let* ((site-id (rf-comments:create-site :key "blog" :name "Blog"
                                             :origins "https://blog.example.com"))
           (site (rf-comments::site-by-id site-id)))
      (is (equal '("https://blog.example.com") (getf site :origins)))
      (is (rf-comments::site-allows-page-p site "https://blog.example.com/x"))
      (is (not (rf-comments::site-allows-page-p site "https://evil.example.com/x")))
      ;; Unverified users may be renamed by a new submission; verified ones may not.
      (let ((u (rf-comments::find-or-create-user "a@example.com" "A")))
        (is (string= "B" (getf (rf-comments::find-or-create-user "a@example.com" "B")
                               :display-name)))
        (rf-comments::mark-user-verified (getf u :id))
        (is (string= "B" (getf (rf-comments::find-or-create-user "a@example.com" "Mallory")
                               :display-name)))
        ;; Comments: pending ones are only visible to their author.
        (let* ((tid (getf (rf-comments::ensure-thread site-id "https://blog.example.com/x"
                                                      "https://blog.example.com/x")
                          :id))
               (cid (rf-comments::create-comment :site-id site-id :thread-id tid
                                                 :user-id (getf u :id)
                                                 :page-url "https://blog.example.com/x"
                                                 :body "hi")))
          (is (null (rf-comments::page-comments tid)))
          (is (= 1 (length (rf-comments::page-comments tid :viewer-id (getf u :id)))))
          ;; Tokens are single use and stored hashed.
          (let ((raw (rf-comments::issue-token (getf u :id) "verify" :comment-id cid)))
            (is (null (rf-comments:query-one "SELECT * FROM tokens WHERE token_hash = ?" raw)))
            (is (null (rf-comments::consume-token raw "login")))
            (is (eql cid (getf (rf-comments::consume-token raw "verify") :comment-id)))
            (is (null (rf-comments::consume-token raw "verify"))))
          ;; Expired tokens are rejected.
          (let ((raw (rf-comments::issue-token (getf u :id) "login" :ttl -10)))
            (is (null (rf-comments::consume-token raw "login"))))
          (is (= 2 (rf-comments::recent-email-count (getf u :id))))
          (rf-comments::set-comment-status cid "published")
          (is (= 1 (length (rf-comments::page-comments tid))))
          (is (getf (rf-comments::comment-by-id cid) :published-at))
          (is (= 1 (length (rf-comments::recent-comments :status "published"))))
          (is (= 0 (length (rf-comments::recent-comments :status "hidden")))))
        ;; Sessions
        (let ((raw (rf-comments::create-session "user" :user-id (getf u :id))))
          (is (rf-comments::find-session raw "user"))
          (is (null (rf-comments::find-session raw "admin")))
          (rf-comments::delete-session raw)
          (is (null (rf-comments::find-session raw "user"))))))))

(test migrations-are-idempotent
  (with-temp-db ()
    (let ((*standard-output* (make-broadcast-stream)))
      (rf-comments::migrate)
      (rf-comments::migrate))
    (is (= (length rf-comments::*migrations*)
           (length (rf-comments:query "SELECT * FROM schema_migrations"))))))

(defun fake-cleaner (x)
  (if (string= x "bad") (values nil (format nil "~a is invalid" x)) (string-upcase x)))

(test with-valid-inputs-macro
  (is (equal '("A" "B")
             (rf-comments::with-valid-inputs ((a fake-cleaner "a") (b fake-cleaner "b"))
                 (:on-error (e) (list :error e))
               (list a b))))
  ;; Stops at the first invalid input and returns the handler's value.
  (let ((evaluated '()))
    (is (equal '(:error "bad is invalid")
               (rf-comments::with-valid-inputs
                   ((a fake-cleaner (progn (push 1 evaluated) "a"))
                    (b fake-cleaner (progn (push 2 evaluated) "bad"))
                    (c fake-cleaner (progn (push 3 evaluated) "c")))
                   (:on-error (e) (list :error e))
                 (list a b c))))
    (is (equal '(2 1) evaluated))))

(test thread-migration-backfills-existing-comments
  ;; Build a database at schema version 2 (before threads existed), with
  ;; comments on two pages, then upgrade it.
  (let ((path (namestring (merge-pathnames (format nil "rf-mig-~a.db" (random-token 6))
                                           (uiop:temporary-directory)))))
    (unwind-protect
         (progn
           (let ((rf-comments::*migrations* (subseq rf-comments::*migrations* 0 2)))
             (with-temp-db (path)
               (rf-comments:exec "INSERT INTO sites (key, name, origins, created_at)
                                  VALUES ('blog', 'Blog', 'https://b.example.com', 'T')")
               (rf-comments:exec "INSERT INTO users (email, display_name, created_at)
                                  VALUES ('a@example.com', 'A', 'T')")
               (loop for (page title) in '(("https://b.example.com/a" "Page A")
                                           ("https://b.example.com/a" "Page A")
                                           ("https://b.example.com/b" "Page B"))
                     do (rf-comments:exec
                         "INSERT INTO comments (site_id, user_id, page_url, page_title, body,
                                                status, created_at)
                          VALUES (1, 1, ?, ?, 'x', 'published', '2026-01-01T00:00:00Z')"
                         page title))))
           (with-temp-db (path)
             (let ((threads (rf-comments:query "SELECT * FROM threads ORDER BY page_key")))
               (is (= 2 (length threads)))
               (is (equal '("https://b.example.com/a" "https://b.example.com/b")
                          (mapcar (lambda (th) (getf th :page-key)) threads)))
               (is (string= "Page A" (getf (first threads) :title))))
             (is (null (rf-comments:query "SELECT * FROM comments WHERE thread_id IS NULL")))
             (is (= 2 (length (rf-comments::page-comments
                               (getf (rf-comments::thread-by-key 1 "https://b.example.com/a")
                                     :id)))))))
      (dolist (suffix '("" "-wal" "-shm"))
        (uiop:delete-file-if-exists (concatenate 'string path suffix))))))

(test page-ids
  (is (string= "post-42" (rf-comments::clean-page-id " post-42 ")))
  (is (string= "blog/2026/hello_world.v2" (rf-comments::clean-page-id "blog/2026/hello_world.v2")))
  (is (null (rf-comments::clean-page-id "has space")))
  (is (null (rf-comments::clean-page-id "<script>")))
  (is (null (rf-comments::clean-page-id (make-string 201 :initial-element #\a)))))

;;; Avatars

(test gravatar-urls
  (let ((rf-comments::*avatar-default* "identicon")
        (rf-comments::*avatar-size* 80))
    ;; SHA-256 of the trimmed, lowercased address (Gravatar's current scheme).
    (is (string= (concatenate 'string
                              "https://gravatar.com/avatar/"
                              "ff8d9819fc0e12bf0d24892e45987e249a28dce836a85cad60e28eaaa8c6d976"
                              "?s=80&d=identicon&r=g")
                 (rf-comments::gravatar-url "  Alice@Example.com ")))))

(test avatar-content-types
  (is (rf-comments::raster-image-type-p "image/png"))
  (is (rf-comments::raster-image-type-p "image/jpeg; charset=binary"))
  (is (not (rf-comments::raster-image-type-p "image/svg+xml")))
  (is (not (rf-comments::raster-image-type-p "text/html")))
  (is (not (rf-comments::raster-image-type-p nil))))

(test fallback-avatar
  (let ((svg (rf-comments::fallback-avatar-svg '(:display-name "  <b>eve" :avatar-key "abc"))))
    (is (search ">B</text>" svg))
    (is (not (search "<b>" svg))))
  (is (search ">?</text>"
              (rf-comments::fallback-avatar-svg '(:display-name "***" :avatar-key "abc")))))

(test avatar-keys-backfilled-and-assigned
  (let ((path (namestring (merge-pathnames (format nil "rf-av-~a.db" (random-token 6))
                                           (uiop:temporary-directory)))))
    (unwind-protect
         (progn
           (let ((rf-comments::*migrations* (subseq rf-comments::*migrations* 0 3)))
             (with-temp-db (path)
               (rf-comments:exec "INSERT INTO users (email, display_name, created_at)
                                  VALUES ('old@example.com', 'Old', 'T')")))
           (with-temp-db (path)
             (let ((old (rf-comments::user-by-email "old@example.com"))
                   (new (rf-comments::find-or-create-user "new@example.com" "New")))
               (is (= 20 (length (getf old :avatar-key))))
               (is (= 20 (length (getf new :avatar-key))))
               (is (string/= (getf old :avatar-key) (getf new :avatar-key)))
               (is (equal old (rf-comments::user-by-avatar-key (getf old :avatar-key)))))))
      (dolist (suffix '("" "-wal" "-shm"))
        (uiop:delete-file-if-exists (concatenate 'string path suffix))))))
