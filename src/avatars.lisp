;;;; avatars.lisp — Gravatar profile images, proxied through this server.
;;;;
;;;; Gravatar identifies a person by the SHA-256 of their (trimmed,
;;;; lowercased) email address. Putting gravatar.com URLs straight into the
;;;; page would publish that hash for every commenter, which can be reversed
;;;; by guessing likely addresses, and would break our "Email (never
;;;; shown)" promise. It would also make every reader's browser call
;;;; gravatar.com. So pages link to /avatar/<avatar_key> (a random per-user
;;;; key), and this server fetches the image from Gravatar, caches it, and
;;;; serves it from our own origin (CSP img-src 'self' stays as it is).
;;;;
;;;; If Gravatar can't be reached, a locally drawn initial is served instead.

(in-package #:rf-comments)

(defvar *avatar-size* 80 "Pixels requested from Gravatar (shown at 40 CSS px, 2x).")
(defvar *avatar-ttl* (* 24 60 60) "Seconds a fetched image is reused.")
(defvar *avatar-cache-limit* 2000 "Cached images before the cache is emptied.")

(defvar *avatar-fetcher* 'fetch-gravatar
  "Function of a URL returning (values octets content-type). Tests replace it.")
(defvar *avatar-cache* (make-hash-table :test #'equal)
  "avatar_key → (octets content-type fetched-at)")
(defvar *avatar-lock* (bt:make-lock "avatar cache"))

(defun avatar-path (avatar-key)
  "URL path of a user's profile image, or NIL when avatars are off."
  (and (eq *avatars* :gravatar) avatar-key (format nil "/avatar/~a" avatar-key)))

(defun gravatar-url (email)
  (format nil "https://gravatar.com/avatar/~a?~a"
          (sha256-hex (string-downcase (trim email)))
          (query-string "s" *avatar-size* "d" *avatar-default* "r" "g")))

(defun fetch-gravatar (url)
  (multiple-value-bind (body status headers)
      (dex:get url :force-binary t :connect-timeout 3 :read-timeout 5 :keep-alive nil)
    (declare (ignore status))
    (values body (gethash "content-type" headers))))

(defun raster-image-type-p (content-type)
  "Only accept bitmap formats from upstream; SVG served from our origin could
carry script."
  (and (stringp content-type)
       (member (string-downcase (string-trim " " (subseq content-type 0
                                                         (or (position #\; content-type)
                                                             (length content-type)))))
               '("image/png" "image/jpeg" "image/gif" "image/webp")
               :test #'string=)))

(defun fallback-avatar-svg (user)
  "A coloured circle with the user's initial, used when Gravatar is unreachable."
  (let* ((name (getf user :display-name))
         (initial (or (find-if #'alphanumericp name) #\?))
         (hue (mod (parse-integer (sha256-hex (or (getf user :avatar-key) "")) :end 4 :radix 16)
                   360)))
    (format nil "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"~d\" height=\"~:*~d\" ~
                 viewBox=\"0 0 80 80\"><rect width=\"80\" height=\"80\" ~
                 fill=\"hsl(~d,45%,52%)\"/><text x=\"40\" y=\"54\" text-anchor=\"middle\" ~
                 font-family=\"system-ui,sans-serif\" font-size=\"38\" fill=\"#fff\">~a</text></svg>"
            *avatar-size* hue (char-upcase initial))))

(defun reset-avatar-cache ()
  (bt:with-lock-held (*avatar-lock*) (clrhash *avatar-cache*)))

(defun avatar-image (user)
  "Image for USER as (values data content-type long-lived-p). Serves the cached
copy while fresh; refetches after *AVATAR-TTL*; falls back to a stale copy,
then to an SVG initial, when Gravatar fails."
  (let* ((key (getf user :avatar-key))
         (now (get-universal-time))
         (cached (bt:with-lock-held (*avatar-lock*) (gethash key *avatar-cache*))))
    (if (and cached (< (- now (third cached)) *avatar-ttl*))
        (values (first cached) (second cached) t)
        (handler-case
            (multiple-value-bind (octets type)
                (funcall *avatar-fetcher* (gravatar-url (getf user :email)))
              (unless (and (typep octets '(vector (unsigned-byte 8)))
                           (plusp (length octets))
                           (raster-image-type-p type))
                (error "unexpected response from Gravatar (~a)" type))
              (bt:with-lock-held (*avatar-lock*)
                (when (>= (hash-table-count *avatar-cache*) *avatar-cache-limit*)
                  (clrhash *avatar-cache*))
                (setf (gethash key *avatar-cache*) (list octets type now)))
              (values octets type t))
          (error (e)
            (format *error-output* "~&;; avatar fetch failed: ~a~%" e)
            (if cached
                (values (first cached) (second cached) nil)
                (values (fallback-avatar-svg user) "image/svg+xml; charset=utf-8" nil)))))))
