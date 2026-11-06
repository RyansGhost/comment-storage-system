;;;; routes.lisp — request plumbing and the route-definition DSL.
;;;;
;;;; In the spirit of "Lisp for the Web" (ch. 2, fighting duplication with
;;;; macros), every HTML route is declared with one of two macros instead
;;;; of a raw EASY-ROUTES:DEFROUTE:
;;;;
;;;;   (defpage   name ("/path" :decorators (...)) (&get ...)  body...)
;;;;   (defaction name ("/path" :decorators (...)) (&post ...) body...)
;;;;
;;;; DEFPAGE is a GET route that gets the default security headers and an
;;;; HTML content type. DEFACTION is a POST route that *always* runs the
;;;; same-origin (CSRF) check first and is never cached, so a new form
;;;; handler cannot forget either. WITH-VALID-INPUTS replaces chains of
;;;; (multiple-value-bind (clean err) (clean-x input) ...) checks.
;;;;
;;;; Non-HTML GET endpoints (scripts, JSON, health) still use DEFROUTE.

(in-package #:rf-comments)

;;; ------------------------------------------------------------------
;;; Request helpers

(defun client-ip ()
  (or (when *trust-proxy*
        (let ((xff (ht:header-in* :x-forwarded-for)))
          (when xff
            (trim (car (last (cl-ppcre:split "," xff)))))))
      (ht:remote-addr*)))

(defun absolute-url (path-or-url)
  (if (local-path-p path-or-url)
      (concatenate 'string *public-url* path-or-url)
      path-or-url))

(defun redirect-to (path-or-url)
  "303 See Other, always to an absolute URL (correct behind a TLS proxy)."
  (ht:redirect (absolute-url path-or-url) :code ht:+http-see-other+))

(defun set-security-headers (&key (frame-ancestors "'none'") (referrer "same-origin")
                                (form-action "'self'"))
  (setf (ht:header-out "X-Content-Type-Options") "nosniff"
        (ht:header-out "Referrer-Policy") referrer
        (ht:header-out "Content-Security-Policy")
        (format nil "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; ~
                     script-src 'self'; form-action ~a; base-uri 'none'; frame-ancestors ~a"
                form-action frame-ancestors)))

(defun respond (html &key (status 200))
  (setf (ht:return-code*) status
        (ht:content-type*) "text/html; charset=utf-8")
  html)

(defun error-page (status title message)
  (set-security-headers)
  (respond (simple-page title message :kind "error") :status status))

(defun origin-ok-p ()
  "True if the request's Origin (or, failing that, Referer) is our own."
  (let* ((ours (url-origin *public-url*))
         (origin (ht:header-in* :origin))
         (referer (ht:header-in* :referer)))
    (cond ((and origin (string/= origin "null")) (equal (url-origin origin) ours))
          (referer (equal (url-origin referer) ours))
          (t nil))))

;;; ------------------------------------------------------------------
;;; Decorators (outermost first in a :DECORATORS list)

(defun @same-origin (next)
  "Reject state-changing requests that don't come from our own pages."
  (if (origin-ok-p)
      (funcall next)
      (error-page 403 "Forbidden" "This form must be submitted from comments pages.")))

(defun @no-cache (next)
  (setf (ht:header-out "Cache-Control") "no-store")
  (funcall next))

(defun @page-headers (next)
  "Default security headers and HTML content type. Handlers that need a
different policy (e.g. the iframe's frame-ancestors) call
SET-SECURITY-HEADERS again, which overrides these."
  (set-security-headers)
  (setf (ht:content-type*) "text/html; charset=utf-8")
  (funcall next))

;;; ------------------------------------------------------------------
;;; Route macros

(defvar *actions* '()
  "Path templates of every DEFACTION route. Each one is CSRF-protected;
the test-suite POSTs to all of them cross-site and expects 403.")

(defmacro defpage (name (path &key decorators) params &body body)
  "Define a GET route that renders HTML with the default security headers."
  `(easy-routes:defroute ,name (,path :method :get
                                      :decorators (@page-headers ,@decorators))
       ,params
     ,@body))

(defmacro defaction (name (path &key decorators) params &body body)
  "Define a POST route. The same-origin check always runs first, then
no-store caching and the default headers, then DECORATORS."
  `(progn
     (pushnew ,path *actions* :test #'string=)
     (easy-routes:defroute ,name (,path :method :post
                                        :decorators (@same-origin @no-cache @page-headers
                                                     ,@decorators))
         ,params
       ,@body)))

(defmacro with-valid-inputs (bindings (on-error (err) &body handler) &body body)
  "Clean and validate inputs in order; stop at the first invalid one.

  (with-valid-inputs ((body  clean-body         raw-body)
                      (email normalize-email    raw-email))
      (:on-error (message) (render-form :error message))
    (save body email))

Each CLEANER returns the cleaned value, or (values NIL message). On the
first NIL, the :ON-ERROR handler runs with ERR bound to the message and
its value is returned; otherwise BODY runs with every VAR bound."
  (assert (eq on-error :on-error) () "Expected (:on-error (err) ...), got ~s" on-error)
  (let ((block (gensym "VALID"))
        (fail (gensym "ON-INVALID")))
    `(block ,block
       (flet ((,fail (,err) ,@handler))
         ,(reduce (lambda (binding inner)
                    (destructuring-bind (var cleaner input) binding
                      (let ((message (gensym "MESSAGE")))
                        `(multiple-value-bind (,var ,message) (,cleaner ,input)
                           (if (null ,var)
                               (return-from ,block (,fail ,message))
                               ,inner)))))
                  bindings
                  :from-end t
                  :initial-value `(progn ,@body))))))
