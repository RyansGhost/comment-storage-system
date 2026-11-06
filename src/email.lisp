;;;; email.lisp — outbound email through the Amazon SES v2 API.
;;;;
;;;; Rather than pull in a whole AWS SDK, we sign one REST call
;;;; (POST /v2/email/outbound-emails) with AWS Signature Version 4.
;;;; See https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv.html
;;;;
;;;; Why no SDK: the maintained CL AWS libraries are large, and we need
;;;; exactly one API call. Signing it ourselves is about 60 lines of code
;;;; and one HTTP POST via Dexador. tests/sigv4.lisp checks the signer
;;;; against AWS's published test vectors and against botocore (the official
;;;; Python implementation), which is what makes hand-rolling it safe.
;;;;
;;;; SigV4 in four steps (each maps to a binding in SIGV4-AUTHORIZATION):
;;;;  1. canonical request: method, path, query, sorted lowercase headers,
;;;;     the list of signed header names, and SHA-256 of the body, joined
;;;;     with newlines. Both sides must build exactly this string.
;;;;  2. string to sign: algorithm, timestamp, *scope*
;;;;     (date/region/service/aws4_request) and SHA-256 of step 1.
;;;;  3. signing key: a chain of HMACs, secret → date → region → service →
;;;;     "aws4_request", so a derived key is only valid for one day, region
;;;;     and service.
;;;;  4. signature = HMAC(signing key, string to sign), sent in the
;;;;     Authorization header together with the scope and header list.
;;;;
;;;; Delivery is synchronous (the request waits for SES, ~100-300 ms), so a
;;;; failure can be reported to the commenter immediately. No job queue is
;;;; needed at this scale.

(in-package #:rf-comments)

;;; ------------------------------------------------------------------
;;; SigV4

(defun amz-date (&optional (universal-time (get-universal-time)))
  "→ \"20261106T154100Z\""
  (multiple-value-bind (s mi h d mo y) (decode-universal-time universal-time 0)
    (format nil "~4,'0d~2,'0d~2,'0dT~2,'0d~2,'0d~2,'0dZ" y mo d h mi s)))

(defun sigv4-signing-key (secret-key date-stamp region service)
  "Derive the SigV4 signing key (a byte vector)."
  (let* ((k-date (hmac-sha256 (concatenate 'string "AWS4" secret-key) date-stamp))
         (k-region (hmac-sha256 k-date region))
         (k-service (hmac-sha256 k-region service)))
    (hmac-sha256 k-service "aws4_request")))

;;; WITH-OUTPUT-TO-STRING binds OUT to a string stream and returns what was
;;; written, CL's StringBuilder. We percent-encode the UTF-8 *bytes*, not
;;; the characters, as RFC 3986 requires.
(defun sigv4-uri-encode (string &key (encode-slash t))
  "RFC 3986 encoding as SigV4 requires (unreserved characters untouched)."
  (with-output-to-string (out)
    (loop for byte across (utf8 string)
          for char = (code-char byte)
          do (cond ((or (char<= #\A char #\Z) (char<= #\a char #\z) (char<= #\0 char #\9)
                        (find char "-_.~"))
                    (write-char char out))
                   ((and (char= char #\/) (not encode-slash))
                    (write-char char out))
                   (t (format out "%~2,'0X" byte))))))

(defun sigv4-canonical-query (params)
  "PARAMS is an alist of (name . value)."
  (format nil "~{~a~^&~}"
          (mapcar (lambda (p) (format nil "~a=~a" (car p) (cdr p)))
                  (sort (mapcar (lambda (p) (cons (sigv4-uri-encode (car p))
                                                  (sigv4-uri-encode (cdr p))))
                                params)
                        (lambda (a b) (or (string< (car a) (car b))
                                          (and (string= (car a) (car b))
                                               (string< (cdr a) (cdr b)))))))))

;;; Returns extra values (the canonical request and string to sign) purely
;;; for debugging: when AWS replies "SignatureDoesNotMatch" it shows its own
;;; canonical request, and comparing it with ours finds the problem fast.
;;; In ~{~a~%~}~% each header line ends with a newline and then comes one
;;; more, producing the blank line SigV4 requires after the header block.
(defun sigv4-authorization (&key (method "GET") (path "/") query headers (payload "")
                              access-key secret-key region service amz-date)
  "Compute the Authorization header value for a request.
HEADERS is an alist of (name . value) and must include host and x-amz-date
(and x-amz-security-token when using temporary credentials). Returns
(values authorization canonical-request string-to-sign)."
  (let* ((headers (sort (mapcar (lambda (h)
                                  (cons (string-downcase (car h))
                                        (cl-ppcre:regex-replace-all
                                         "\\s+" (trim (cdr h)) " ")))
                                headers)
                        #'string< :key #'car))
         (signed-headers (format nil "~{~a~^;~}" (mapcar #'car headers)))
         (canonical-request
           (format nil "~a~%~a~%~a~%~{~a~%~}~%~a~%~a"
                   method
                   (sigv4-uri-encode path :encode-slash nil)
                   (sigv4-canonical-query query)
                   (mapcar (lambda (h) (format nil "~a:~a" (car h) (cdr h))) headers)
                   signed-headers
                   (sha256-hex payload)))
         (date-stamp (subseq amz-date 0 8))
         (scope (format nil "~a/~a/~a/aws4_request" date-stamp region service))
         (string-to-sign (format nil "AWS4-HMAC-SHA256~%~a~%~a~%~a"
                                 amz-date scope (sha256-hex canonical-request)))
         (signature (ironclad:byte-array-to-hex-string
                     (hmac-sha256 (sigv4-signing-key secret-key date-stamp region service)
                                  string-to-sign))))
    (values (format nil "AWS4-HMAC-SHA256 Credential=~a/~a, SignedHeaders=~a, Signature=~a"
                    access-key scope signed-headers signature)
            canonical-request
            string-to-sign)))

;;; ------------------------------------------------------------------
;;; SES v2 SendEmail
;;;
;;; Building JSON with jzon: hash tables become JSON objects, vectors become
;;; arrays, strings and numbers map directly. (Lists are avoided on purpose:
;;; a Lisp list is ambiguous between object and array.) The little OBJ
;;; helper builds an object from key/value pairs, skipping NIL values, so
;;; the optional Html part simply disappears when there is no HTML.

(defun ses-payload (to subject text html)
  (let ((h (make-hash-table :test #'equal)))
    (flet ((obj (&rest kv)
             (let ((o (make-hash-table :test #'equal)))
               (loop for (k v) on kv by #'cddr when v do (setf (gethash k o) v))
               o)))
      (setf (gethash "FromEmailAddress" h) *ses-from*
            (gethash "Destination" h) (obj "ToAddresses" (vector to))
            (gethash "Content" h)
            (obj "Simple"
                 (obj "Subject" (obj "Data" subject "Charset" "UTF-8")
                      "Body" (obj "Text" (obj "Data" text "Charset" "UTF-8")
                                  "Html" (when html (obj "Data" html "Charset" "UTF-8"))))))
      (when *ses-configuration-set*
        (setf (gethash "ConfigurationSetName" h) *ses-configuration-set*)))
    (jzon:stringify h)))

;;; Dexador calls look like (dex:post url :headers alist :content body).
;;; On a 4xx/5xx response it *signals* DEX:HTTP-REQUEST-FAILED rather than
;;; returning. SEND-EMAIL below handles that. We pass the body as UTF-8
;;; octets so the bytes sent are exactly the bytes hashed into the
;;; signature. Dexador sets the Host header itself from the URL, so ours is
;;; removed from the list it gets (it was only needed for signing).
(defun ses-send (to subject text html)
  (let* ((host (format nil "email.~a.amazonaws.com" *aws-region*))
         (path "/v2/email/outbound-emails")
         (payload (ses-payload to subject text html))
         (date (amz-date))
         (headers `(("content-type" . "application/json")
                    ("host" . ,host)
                    ("x-amz-date" . ,date)
                    ,@(when *aws-session-token*
                        `(("x-amz-security-token" . ,*aws-session-token*)))))
         (authorization (sigv4-authorization
                         :method "POST" :path path :headers headers :payload payload
                         :access-key *aws-access-key-id* :secret-key *aws-secret-access-key*
                         :region *aws-region* :service "ses" :amz-date date)))
    (dex:post (format nil "https://~a~a" host path)
              :headers (append (remove "host" headers :key #'car :test #'string=)
                               `(("authorization" . ,authorization)))
              ;; Send exactly the bytes that were signed.
              :content (utf8 payload))
    t))

;;; ------------------------------------------------------------------
;;; Front door

(defvar *captured-emails* '()
  "With EMAIL-BACKEND :CAPTURE, sent emails are pushed here as plists.")

;;; The single entry point for all mail. The backend switch (*EMAIL-BACKEND*)
;;; makes development (:log prints the links to the REPL) and testing
;;; (:capture, inspected by the tests) need no AWS account. ECASE is a CASE
;;; that signals an error when nothing matches, so a typo'd backend can't
;;; silently drop email.
;;;
;;; Failures are *returned* (NIL) rather than signalled. A comment is saved
;;; even if its email can't be sent, and the page tells the user what
;;; happened, rather than showing a 500 error.
(defun send-email (to subject text &key html)
  "Send an email. Returns true on success; failures are logged, not raised."
  (handler-case
      (ecase *email-backend*
        (:ses (ses-send to subject text html))
        (:log (format t "~&;; ---- email to ~a ----~%;; Subject: ~a~%~a~%;; ----~%"
                      to subject text)
              (finish-output)
              t)
        (:capture (push (list :to to :subject subject :text text :html html)
                        *captured-emails*)
                  t))
    (dex:http-request-failed (e)
      (format *error-output* "~&;; SES error ~a sending to ~a: ~a~%"
              (dex:response-status e) to (dex:response-body e))
      nil)
    (error (e)
      (format *error-output* "~&;; email error sending to ~a: ~a~%" to e)
      nil)))

;;; ------------------------------------------------------------------
;;; Message templates
;;;
;;; Every email carries both a plain-text and an HTML part (text-only
;;; clients, spam scoring). HTML email needs inline styles because most mail
;;; clients strip <style> blocks. Spinneret escapes INTRO etc., so user
;;; names can't inject markup into an email either.

(defun link-email (to &key subject intro link button outro)
  (let ((text (format nil "~a~%~%~a~%~%~a~%~%— comments.ryanfleck.ca~%" intro link outro))
        (html (spinneret:with-html-string
                (:div :style "font-family:system-ui,sans-serif;max-width:32rem;line-height:1.5"
                      (:p intro)
                      (:p (:a :href link
                              :style "display:inline-block;padding:.6rem 1rem;background:#2563eb;color:#fff;border-radius:6px;text-decoration:none"
                              button))
                      (:p :style "color:#666;font-size:.9em" outro)
                      (:p :style "color:#666;font-size:.8em;word-break:break-all" link)))))
    (send-email to subject text :html html)))

(defun send-verification-email (user comment-id token page-url)
  (link-email (getf user :email)
              :subject "Confirm your comment"
              :intro (format nil "Hi ~a, thanks for commenting on ~a. Please confirm your email address to publish your comment."
                             (getf user :display-name) page-url)
              :link (format nil "~a/verify?~a" *public-url* (query-string "token" token))
              :button "Publish my comment"
              :outro (format nil "This link expires in ~d hours. If you didn't write comment #~d, ignore this email and it will never appear."
                             (round *token-ttl* 3600) comment-id)))

(defun send-login-email (user token)
  (link-email (getf user :email)
              :subject "Your sign-in link"
              :intro (format nil "Hi ~a, here is your link to sign in to the comment system."
                             (getf user :display-name))
              :link (format nil "~a/login/callback?~a" *public-url* (query-string "token" token))
              :button "Sign in"
              :outro (format nil "This link expires in ~d hours and works once. If you didn't ask to sign in, ignore this email."
                             (round *token-ttl* 3600))))
