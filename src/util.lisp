;;;; util.lisp — time, tokens, hashing, URL and input validation.
;;;;
;;;; Small, pure-ish helpers with no knowledge of HTTP or the database. They
;;;; are easy to try at the REPL, e.g. (canonical-page-url "https://X.com/a/index.html?q").
;;;;
;;;; A Common Lisp idiom used throughout: functions that can fail return
;;;; MULTIPLE VALUES, (values nil "why it failed"), instead of signalling an
;;;; error. A caller that only wants the result just uses the first value
;;;; (extra values are silently dropped). A caller that wants the message
;;;; uses MULTIPLE-VALUE-BIND, or the WITH-VALID-INPUTS macro from
;;;; routes.lisp.

(in-package #:rf-comments)

;;; ------------------------------------------------------------------
;;; Time — all timestamps are UTC ISO-8601 strings: "2026-11-06T15:41:00Z"
;;; They are readable in sqlite3 and sort correctly as text.

;;; Common Lisp's clock is the *universal time*: seconds since 1900-01-01
;;; UTC (GET-UNIVERSAL-TIME). DECODE-UNIVERSAL-TIME splits it into
;;; components. Passing time zone 0 gives UTC regardless of the server's
;;; locale. In the FORMAT string, ~4,'0d prints an integer padded to 4
;;; digits with zeros.
(defun iso-time (&optional (universal-time (get-universal-time)))
  (multiple-value-bind (s mi h d mo y) (decode-universal-time universal-time 0)
    (format nil "~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d:~2,'0dZ" y mo d h mi s)))

(defun iso-in (seconds)
  "ISO time SECONDS from now (negative for the past)."
  (iso-time (+ (get-universal-time) seconds)))

;;; HANDLER-CASE is CL's try/catch: if anything in the body signals an
;;; ERROR, return the original string rather than failing the whole page
;;; render over a malformed date.
(defun human-date (iso)
  "2026-11-06T15:41:00Z → \"Nov 6, 2026\"."
  (handler-case
      (let ((y (parse-integer iso :start 0 :end 4))
            (m (parse-integer iso :start 5 :end 7))
            (d (parse-integer iso :start 8 :end 10)))
        (format nil "~a ~d, ~d"
                (nth (1- m) '("Jan" "Feb" "Mar" "Apr" "May" "Jun"
                              "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"))
                d y))
    (error () iso)))

;;; ------------------------------------------------------------------
;;; Crypto helpers
;;;
;;; Ironclad works on octet vectors, (simple-array (unsigned-byte 8) (*)),
;;; not strings, so strings go through BABEL to UTF-8 first. Never hash a
;;; Lisp string's internal representation; always pick an encoding.

(defun utf8 (string)
  (babel:string-to-octets string :encoding :utf-8))

(defun sha256-bytes (data)
  (ironclad:digest-sequence :sha256 (if (stringp data) (utf8 data) data)))

(defun sha256-hex (data)
  (ironclad:byte-array-to-hex-string (sha256-bytes data)))

(defun hmac-sha256 (key data)
  (let ((mac (ironclad:make-hmac (if (stringp key) (utf8 key) key) :sha256)))
    (ironclad:update-hmac mac (if (stringp data) (utf8 data) data))
    (ironclad:hmac-digest mac)))

;;; IRONCLAD:RANDOM-DATA uses the operating system's cryptographic RNG
;;; (/dev/urandom). Do NOT use CL:RANDOM for secrets: it's a predictable
;;; PRNG meant for simulations. 32 bytes = 256 bits, hex encoded to 64 chars
;;; so tokens are safe in URLs and cookies without further escaping.
(defun random-token (&optional (bytes 32))
  "A URL-safe random token with BYTES bytes of entropy (hex encoded)."
  (ironclad:byte-array-to-hex-string (ironclad:random-data bytes)))

;;; Used for the admin password. A plain STRING= returns as soon as a
;;; character differs, so response time leaks how much of a guess was right.
;;; Hashing both sides first gives equal-length inputs, and
;;; CONSTANT-TIME-EQUAL always inspects every byte.
(defun constant-time-string= (a b)
  "Compare two strings without leaking where they differ."
  (and (stringp a) (stringp b)
       (let ((ha (sha256-bytes a)) (hb (sha256-bytes b)))
         (ironclad:constant-time-equal ha hb))))

;;; ------------------------------------------------------------------
;;; Strings

(defun trim (s)
  (string-trim '(#\Space #\Tab #\Newline #\Return #\Page #\No-break_space) (or s "")))

(defun blank-p (s) (zerop (length (trim s))))

(defun strip-control-chars (s)
  "Remove control characters except newline and tab."
  (remove-if (lambda (c)
               (let ((code (char-code c)))
                 (and (or (< code 32) (= code 127))
                      (not (member c '(#\Newline #\Tab))))))
             s))

(defun normalize-newlines (s)
  (cl-ppcre:regex-replace-all "\\r\\n?" s (string #\Newline)))

(defun truncate-string (s n)
  (if (> (length s) n) (concatenate 'string (subseq s 0 (max 0 (1- n))) "…") s))

;;; ------------------------------------------------------------------
;;; Input validation. Each CLEAN-* function returns the cleaned value, or
;;; (values NIL "error message").
;;;
;;; Validation is deliberately done on the server, even though the HTML
;;; form also has `required`/`maxlength` attributes: browsers can be
;;; bypassed with curl, so the server never trusts what it receives.

;;; CL-PPCRE:CREATE-SCANNER compiles a regex once, at load time, into a
;;; closure. Passing the scanner (instead of the pattern string) to SCAN
;;; skips recompiling on every call. (With a literal string pattern,
;;; cl-ppcre also caches compiled patterns via compiler macros, so the
;;; inline patterns below are fine too.)
;;; The pattern is intentionally loose: real validation of an email address
;;; is "can it receive our verification email?", which is exactly what the
;;; verify-link flow tests.
(defparameter +email-scanner+
  (cl-ppcre:create-scanner "^[^@\\s<>\"']+@[^@\\s<>\"']+\\.[^@\\s<>\"'.]+$"))

(defun normalize-email (email)
  (let ((e (string-downcase (trim email))))
    (cond ((blank-p e) (values nil "Please enter your email address."))
          ((or (> (length e) 254) (not (cl-ppcre:scan +email-scanner+ e)))
           (values nil "That email address doesn't look right."))
          (t e))))

(defun clean-display-name (name)
  (let ((n (cl-ppcre:regex-replace-all "\\s+" (strip-control-chars (trim name)) " ")))
    (cond ((blank-p n) (values nil "Please enter a display name."))
          ((> (length n) *max-name-length*)
           (values nil (format nil "Display names are limited to ~d characters."
                               *max-name-length*)))
          (t n))))

(defun clean-body (body)
  (let ((b (trim (strip-control-chars (normalize-newlines (or body ""))))))
    (cond ((blank-p b) (values nil "Your comment is empty."))
          ((> (length b) *max-body-length*)
           (values nil (format nil "Comments are limited to ~:d characters."
                               *max-body-length*)))
          (t b))))

(defun clean-title (title)
  (truncate-string (cl-ppcre:regex-replace-all "\\s+" (strip-control-chars (trim title)) " ")
                   200))

(defun clean-page-id (id)
  "Validate an embed's data-page-id (like disqus_identifier)."
  (let ((id (trim id)))
    (if (and (<= 1 (length id) 200) (cl-ppcre:scan "^[A-Za-z0-9._:/-]+$" id))
        id
        (values nil "Invalid page id: use 1-200 letters, digits or . _ : / -"))))

(defun valid-site-key-p (key)
  (and (stringp key) (<= 1 (length key) 40)
       (cl-ppcre:scan "^[a-z0-9][a-z0-9-]*$" key)))

;;; ------------------------------------------------------------------
;;; URLs
;;;
;;; QURI parses URLs into objects with readers (uri-scheme, uri-host,
;;; uri-port, uri-path…). We reduce URLs to two derived forms:
;;;   origin             scheme://host[:port]: the unit browsers use for
;;;                      security (CORS, CSP frame-ancestors, Origin header)
;;;   canonical page URL origin + path: the identity of a comment thread
;;;                      when the embed gives no data-page-id

(defun default-port-p (scheme port)
  (or (null port)
      (and (string= scheme "http") (= port 80))
      (and (string= scheme "https") (= port 443))))

(defun parse-http-url (string)
  "Parse STRING as an absolute http(s) URL. Returns a QURI object or NIL."
  (let ((uri (ignore-errors (quri:uri (trim string)))))
    (when (and uri
               (member (quri:uri-scheme uri) '("http" "https") :test #'equalp)
               (quri:uri-host uri)
               (plusp (length (quri:uri-host uri))))
      uri)))

(defun uri-origin (uri)
  (let ((scheme (string-downcase (quri:uri-scheme uri)))
        (host (string-downcase (quri:uri-host uri)))
        (port (quri:uri-port uri)))
    (if (default-port-p scheme port)
        (format nil "~a://~a" scheme host)
        (format nil "~a://~a:~d" scheme host port))))

(defun url-origin (string)
  "\"https://Blog.example.com/x?y\" → \"https://blog.example.com\" (or NIL)."
  (let ((uri (parse-http-url string)))
    (and uri (uri-origin uri))))

(defun canonical-page-url (string)
  "Canonical identity of a page: origin + path, without query or fragment,
and with a trailing index.html removed. Returns NIL for non-http URLs."
  (let ((uri (parse-http-url string)))
    (when uri
      (let ((path (or (quri:uri-path uri) "")))
        (setf path (cl-ppcre:regex-replace "/index\\.html?$" path "/"))
        (when (zerop (length path)) (setf path "/"))
        (concatenate 'string (uri-origin uri) path)))))

(defun parse-origins (text)
  "Parse a newline/comma/space separated list of origins. Returns
(values origins invalid-entries)."
  (let ((origins '()) (invalid '()))
    (dolist (entry (cl-ppcre:split "[\\s,]+" (or text "")))
      (unless (blank-p entry)
        (let ((origin (url-origin entry)))
          (if origin
              (pushnew origin origins :test #'string=)
              (push entry invalid)))))
    (values (nreverse origins) (nreverse invalid))))

;;; Guards every redirect that takes a user-supplied target (e.g. logout's
;;; ?return=). Without it, /logout?return=https://evil.example would make our
;;; domain bounce users to an attacker's site (an "open redirect"). "//evil"
;;; and "/\\evil" are rejected because browsers treat them as
;;; protocol-relative URLs to another host.
(defun local-path-p (path)
  "True for a same-origin relative path that is safe to redirect to."
  (and (stringp path) (plusp (length path))
       (char= (char path 0) #\/)
       (not (uiop:string-prefix-p "//" path))
       (not (find #\\ path))))

(defun url-encode (s) (quri:url-encode (or s "")))

;;; LOOP ... ON PAIRS BY #'CDDR walks a plist two elements at a time,
;;; destructuring each step into (k v). ~{~a~^&~} is FORMAT's list
;;; iteration: print each element, with "&" between (~^ stops before the
;;; last separator).
(defun query-string (&rest pairs)
  "(query-string \"a\" 1 \"b\" \"x y\") → \"a=1&b=x%20y\"; NIL values are skipped."
  (format nil "~{~a~^&~}"
          (loop for (k v) on pairs by #'cddr
                when v collect (format nil "~a=~a" k (url-encode (princ-to-string v))))))

;;; ------------------------------------------------------------------
;;; Rendering a comment body: plain text → paragraphs with line breaks.
;;; Returns a list of paragraphs, each a list of lines; the view layer
;;; turns them into escaped HTML.

(defun render-body (body)
  (mapcar (lambda (para) (cl-ppcre:split "\\n" para))
          (remove-if #'blank-p (cl-ppcre:split "\\n\\s*\\n" (or body "")))))

;;; ------------------------------------------------------------------
;;; A tiny in-memory sliding-window rate limiter.
;;;
;;; *RATE-BUCKETS* maps a key such as (:comment "203.0.113.9") to a list of
;;; hit timestamps. The hash table is EQUAL so list keys compare by
;;; structure. It's shared by all request threads, and hash tables aren't
;;; thread-safe for concurrent writes, so every access holds *RATE-LOCK*
;;; (BT:WITH-LOCK-HELD is a portable lock + unwind-protect).
;;;
;;; In memory, so limits reset on restart and aren't shared between
;;; processes. That's fine for a single small container; a multi-instance
;;; deployment would need the database or Redis instead.

(defvar *rate-lock* (bt:make-lock "rate-limit"))
(defvar *rate-buckets* (make-hash-table :test #'equal))

(defun rate-limited-p (key limit window)
  "Record a hit for KEY and return true if KEY exceeded LIMIT hits in the
last WINDOW seconds (the hit is not recorded when limited)."
  (let ((now (get-universal-time)))
    (bt:with-lock-held (*rate-lock*)
      (let ((hits (remove-if (lambda (time) (<= time (- now window)))
                             (gethash key *rate-buckets*))))
        (cond ((>= (length hits) limit)
               (setf (gethash key *rate-buckets*) hits)
               t)
              (t (setf (gethash key *rate-buckets*) (cons now hits))
                 nil))))))

(defun reset-rate-limits ()
  (bt:with-lock-held (*rate-lock*) (clrhash *rate-buckets*)))
