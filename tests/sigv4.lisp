;;;; tests/sigv4.lisp — AWS Signature V4, checked against AWS's published
;;;; examples and against signatures produced by botocore (the reference
;;;; Python implementation) for the same inputs.

(in-package #:rf-comments/tests)
;;;
;;; Known-answer tests are the right tool for crypto code: an implementation
;;; that's "almost right" produces a completely different signature, so a
;;; single matching vector proves every step (canonicalisation, hashing,
;;; key derivation) is exactly right. The botocore values were produced by
;;; running botocore's SigV4Auth with a frozen clock on the same inputs.

(def-suite sigv4 :in all)
(in-suite sigv4)

(defparameter +key-id+ "AKIDEXAMPLE")
(defparameter +secret+ "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")

(defun signature-of (authorization)
  (subseq authorization (+ (search "Signature=" authorization) 10)))

(test signing-key-derivation
  ;; https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-create-signed-request.html
  (is (string= "f4780e2d9f65fa895f9c67b32ce1baf0b0d8a43505a000a1a9e090d414db404d"
               (ironclad:byte-array-to-hex-string
                (rf-comments:sigv4-signing-key +secret+ "20120215" "us-east-1" "iam")))))

(test aws-suite-get-vanilla
  ;; The "get-vanilla" case from the AWS SigV4 test suite.
  (let ((auth (rf-comments:sigv4-authorization
               :method "GET" :path "/"
               :headers '(("Host" . "example.amazonaws.com")
                          ("X-Amz-Date" . "20150830T123600Z"))
               :access-key +key-id+ :secret-key +secret+
               :region "us-east-1" :service "service" :amz-date "20150830T123600Z")))
    (is (string= (concatenate 'string
                              "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, "
                              "SignedHeaders=host;x-amz-date, "
                              "Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
                 auth))))

(test botocore-query-and-path
  (is (string= "0f85a39641154786aecead9e57d46d275e12ce098ad4b32d0938839eefe618e2"
               (signature-of
                (rf-comments:sigv4-authorization
                 :method "GET" :path "/a b/"
                 :query '(("Param2" . "value2") ("Param1" . "value1"))
                 :headers '(("host" . "example.amazonaws.com")
                            ("x-amz-date" . "20150830T123600Z"))
                 :access-key +key-id+ :secret-key +secret+
                 :region "us-east-1" :service "service" :amz-date "20150830T123600Z")))))

(test botocore-ses-send-email
  ;; Same request shape the service sends to SES (POST JSON, UTF-8 body).
  (let ((body (format nil "{\"FromEmailAddress\":\"a@example.com\",\"Content\":{\"Simple\":{\"Subject\":{\"Data\":\"Hi ~C\"}}}}"
                      (code-char 252))))
    (is (string= "e73e435611afb387f6e6fedc28bdd06a5177d835afe45d1cf9bae416e5845e4f"
                 (signature-of
                  (rf-comments:sigv4-authorization
                   :method "POST" :path "/v2/email/outbound-emails"
                   :headers '(("content-type" . "application/json")
                              ("host" . "email.ca-central-1.amazonaws.com")
                              ("x-amz-date" . "20150830T123600Z"))
                   :payload body
                   :access-key +key-id+ :secret-key +secret+
                   :region "ca-central-1" :service "ses" :amz-date "20150830T123600Z"))))))

(test ses-payload-shape
  (let* ((rf-comments:*ses-from* "Comments <c@example.com>")
         (rf-comments:*ses-configuration-set* nil)
         (json (com.inuoe.jzon:parse (rf-comments::ses-payload "to@example.com" "Subj" "Text" "<p>x</p>"))))
    (is (string= "Comments <c@example.com>" (gethash "FromEmailAddress" json)))
    (is (equalp #("to@example.com") (gethash "ToAddresses" (gethash "Destination" json))))
    (let ((simple (gethash "Simple" (gethash "Content" json))))
      (is (string= "Subj" (gethash "Data" (gethash "Subject" simple))))
      (is (string= "Text" (gethash "Data" (gethash "Text" (gethash "Body" simple)))))
      (is (string= "<p>x</p>" (gethash "Data" (gethash "Html" (gethash "Body" simple))))))
    (is (null (nth-value 1 (gethash "ConfigurationSetName" json))))))
