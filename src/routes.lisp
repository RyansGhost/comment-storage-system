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
;;;;
;;;; ----------------------------------------------------------------------
;;;; How a request flows through Hunchentoot and easy-routes
;;;; ----------------------------------------------------------------------
;;;; 1. An *acceptor* (APP-ACCEPTOR in web.lisp, created in main.lisp) listens
;;;;    on a port. Its default *taskmaster* spawns one thread per connection.
;;;; 2. For each request, Hunchentoot binds two special variables in that
;;;;    thread: HUNCHENTOOT:*REQUEST* (what came in) and *REPLY* (what will
;;;;    go out). The "starred" accessors read or write the *current* one
;;;;    without passing it around:
;;;;      (ht:header-in* :origin)           request header
;;;;      (ht:get-parameter "x")            query-string parameter
;;;;      (ht:post-parameter "x")           form field
;;;;      (ht:cookie-in "name")             cookie
;;;;      (setf (ht:header-out "X-Foo") v)  response header
;;;;      (setf (ht:return-code*) 404)      status code
;;;;      (setf (ht:content-type*) "…")     Content-Type
;;;;    This works because each request has its own thread, and special
;;;;    variable bindings are per thread.
;;;; 3. easy-routes' acceptor matches the path and method against routes
;;;;    declared with EASY-ROUTES:DEFROUTE, binds the URL's :params, and
;;;;    calls the route function.
;;;; 4. Whatever the route function *returns*, a string or an octet vector,
;;;;    becomes the response body. There is no response object to build.
;;;; 5. HT:REDIRECT (and ABORT-REQUEST-HANDLER) end handling early with a
;;;;    non-local exit, like an exception, so code after them never runs.
;;;;
;;;; Decorators are easy-routes' middleware: a decorator is a function
;;;; (lambda (next) …) that may do work before or after calling NEXT, or
;;;; answer itself and never call it (e.g. a 403 from @SAME-ORIGIN). In a
;;;; :DECORATORS list the first one is the outermost wrapper.

(in-package #:rf-comments)

;;; ------------------------------------------------------------------
;;; Request helpers

;;; Behind a reverse proxy (Caddy/nginx), every connection comes *from the
;;; proxy*, so REMOTE-ADDR is useless and the real client is in
;;; X-Forwarded-For. A client can send its own fake X-Forwarded-For, but the
;;; proxy *appends* the address it actually saw, so only the LAST entry is
;;; trustworthy. Hunchentoot's REAL-REMOTE-ADDR takes the first, which is
;;; why we don't use it.
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

;;; 303 See Other after a POST is the Post/Redirect/Get pattern: the
;;; browser follows with a GET, so reload doesn't re-submit the form.
;;; Hunchentoot can build absolute URLs itself, but behind a TLS-terminating
;;; proxy it sees plain http, so we build them from *PUBLIC-URL* instead.
(defun redirect-to (path-or-url)
  "303 See Other, always to an absolute URL (correct behind a TLS proxy)."
  (ht:redirect (absolute-url path-or-url) :code ht:+http-see-other+))

;;; Defence in depth for every HTML response:
;;;   X-Content-Type-Options: nosniff   don't guess types (no HTML-from-JSON)
;;;   Referrer-Policy                   don't leak our URLs (which may hold
;;;                                     tokens) to other sites
;;;   Content-Security-Policy           what the page may load and do:
;;;     script-src 'self'   only our own .js files, so no inline scripts and
;;;                         therefore no injected ones, even if escaping
;;;                         somehow failed
;;;     form-action         where forms may submit (and redirect)
;;;     frame-ancestors     who may embed us in an iframe ('none' except
;;;                         for the comment thread, which allows the site's
;;;                         own origins)
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

;;; CSRF protection. A malicious page can make the visitor's browser POST a
;;; form to us, and the browser attaches our cookies. Browsers also tell us
;;; where a request came from, in headers the attacker's page cannot forge.
;;; Every POST must pass two checks, in the terms of OWASP's CSRF Prevention
;;; Cheat Sheet
;;; (https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html):
;;;
;;;  1. Fetch Metadata, one of OWASP's *primary* defences for software that
;;;     targets modern browsers. Browsers send Sec-Fetch-Site on every
;;;     request (all major browsers since March 2023, per OWASP). We accept
;;;     only "same-origin". "cross-site", "same-site" (another
;;;     *.ryanfleck.ca subdomain) and "none" are rejected; every legitimate
;;;     form in this app posts to its own origin, the iframe's included.
;;;  2. Origin, or Referer when Origin is absent, must equal our origin.
;;;     OWASP lists this check under "Defense In Depth", and makes it the
;;;     *mandatory* fallback for browsers that don't send Fetch Metadata.
;;;     A present Origin must match, so "Origin: null" fails (URL-ORIGIN
;;;     returns NIL for it). Opaque origins such as sandboxed iframes
;;;     produce "null", and an attacker can create one, so OWASP says
;;;     never to treat it as same-origin.
;;;
;;; SameSite cookies (set in web.lisp and admin.lisp) are a third,
;;; defence-in-depth layer.
;;;
;;; Why not CSRF tokens, OWASP's first recommendation for broad browser
;;; support? Every form here is server-rendered and posted same-origin;
;;; modern browsers get the Fetch Metadata check, and older ones still send
;;; Origin on POST. Because the check lives in DEFACTION, no new route can
;;; forget it. If very old browsers ever matter, tokens are the upgrade path.
(defun same-origin-request-p ()
  "True if this request comes from one of our own pages, judged by Fetch
Metadata (when sent) and by Origin, or Referer when Origin is absent."
  (let ((ours (url-origin *public-url*))
        (fetch-site (ht:header-in* :sec-fetch-site))
        (origin (ht:header-in* :origin))
        (referer (ht:header-in* :referer)))
    (and (or (null fetch-site) (string= fetch-site "same-origin"))
         (cond (origin (equal (url-origin origin) ours))
               (referer (equal (url-origin referer) ours))
               (t nil)))))

;;; ------------------------------------------------------------------
;;; Decorators (outermost first in a :DECORATORS list)

(defun @same-origin (next)
  "Reject state-changing requests that don't come from our own pages."
  (if (same-origin-request-p)
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
;;;
;;; These expand into EASY-ROUTES:DEFROUTE with a decorator list assembled
;;; at macroexpansion time. Try (macroexpand-1 '(defaction foo ("/x") ()
;;; :body)) in the REPL to see the result. A route macro means every new
;;; handler inherits the security defaults by construction, rather than
;;; depending on each author remembering them.
;;;
;;; DEFROUTE's parameter list, (&get a b &post c &path (id 'integer)), binds
;;; query parameters, form fields and typed URL segments to variables. A
;;; missing parameter is NIL. The route name is also a DEFUN, so
;;; (return-from post-comment …) works inside its body.

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

;;; Implementation notes: GENSYM'd names for the BLOCK and the FLET keep the
;;; macro *hygienic*, so a user's body that defines its own block or
;;; function with the same name can't collide with ours. REDUCE :FROM-END T
;;; builds the nested MULTIPLE-VALUE-BINDs from the inside out, so the first
;;; binding ends up outermost and is checked first.
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
