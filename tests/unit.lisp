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
        (let ((cid (rf-comments::create-comment :site-id site-id :user-id (getf u :id)
                                                :page-url "https://blog.example.com/x"
                                                :body "hi")))
          (is (null (rf-comments::page-comments site-id "https://blog.example.com/x")))
          (is (= 1 (length (rf-comments::page-comments site-id "https://blog.example.com/x"
                                                       :viewer-id (getf u :id)))))
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
          (is (= 1 (length (rf-comments::page-comments site-id "https://blog.example.com/x"))))
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
