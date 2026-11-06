;;;; email.lisp — outbound email through the Amazon SES v2 API.
;;;;
;;;; Rather than pull in a whole AWS SDK, we sign one REST call
;;;; (POST /v2/email/outbound-emails) with AWS Signature Version 4.
;;;; See https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv.html

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
