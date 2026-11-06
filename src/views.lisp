;;;; views.lisp — HTML layout, CSS and site themes (Spinneret).
;;;;
;;;; Spinneret escapes every string it prints, so user content is always
;;;; safe to interpolate. Only CSS we generate ourselves goes through :RAW.
;;;;
;;;; ----------------------------------------------------------------------
;;;; Spinneret in five minutes
;;;; ----------------------------------------------------------------------
;;;; Spinneret turns s-expressions into HTML:
;;;;
;;;;   (spinneret:with-html-string
;;;;     (:p.note :id "x" "Hello, " name))   →  <p class=note id=x>Hello, Bob
;;;;
;;;; * A list starting with a keyword is a tag. :tag.class#id is shorthand
;;;;   for class and id attributes.
;;;; * Keyword/value pairs right after the tag are attributes. A NIL value
;;;;   omits the attribute, and T writes a boolean attribute (:required t).
;;;; * Remaining forms are children: strings and other values are printed
;;;;   *HTML-escaped*, so user input can't inject markup. That's the main
;;;;   reason we chose Spinneret over CL-WHO (the book's library), where
;;;;   escaping is opt-in (ESCAPE-STRING) and therefore easy to forget.
;;;; * Ordinary Lisp works anywhere inside: (dolist …), (when …),
;;;;   (if …). Tag forms inside them are still recognised, because
;;;;   WITH-HTML walks the code at macroexpansion time.
;;;; * (:raw string) inserts STRING unescaped. We use it only for CSS we
;;;;   generated ourselves.
;;;; * WITH-HTML-STRING returns the HTML as a string. WITH-HTML (no -STRING)
;;;;   writes to the stream in SPINNERET:*HTML*, which is how helper
;;;;   functions like COMMENT-BODY-HTML emit fragments into a page being
;;;;   built by their caller: they print, rather than return, their markup.
;;;; * Spinneret pretty-prints when *PRINT-PRETTY* is true. We bind it to NIL
;;;;   for compact output (smaller pages, and no whitespace surprises in
;;;;   inline layouts).
;;;;
;;;; CSS lives in Lisp strings rather than separate files so the saved
;;;; executable is self-contained (no static directory to ship) and pages
;;;; render in one request. Themes are CSS custom properties (--rf-accent
;;;; …) that each site's theme overrides.

(in-package #:rf-comments)

(defparameter *base-css* "
:root{--rf-accent:#2563eb;--rf-text:#1f2328;--rf-muted:#656d76;--rf-bg:transparent;
--rf-surface:#ffffff;--rf-border:#d0d7de;--rf-radius:8px;
--rf-font:system-ui,-apple-system,'Segoe UI',Roboto,'Helvetica Neue',Arial,sans-serif;
--rf-danger:#cf222e;--rf-ok:#1a7f37;color-scheme:light}
*{box-sizing:border-box}
html,body{margin:0;padding:0}
body{background:var(--rf-bg);color:var(--rf-text);font:15px/1.55 var(--rf-font)}
a{color:var(--rf-accent)}
.rf{padding:4px 2px 8px}
.rf h2{font-size:1.1em;margin:0 0 .75em}
.rf-list{list-style:none;margin:0 0 1.25em;padding:0}
.rf-comment{padding:.75em 0;border-top:1px solid var(--rf-border);display:flex;gap:.75em;
align-items:flex-start}
.rf-main{flex:1;min-width:0}
.rf-avatar{width:40px;height:40px;border-radius:50%;flex:none;background:var(--rf-border);
object-fit:cover}
.rf-hello{display:flex;gap:.75em;align-items:center;margin:0 0 1em}
.rf-hello h1{margin:0}
.rf-footer .rf-attribution{display:block;margin-top:.25em}
.rf-comment:first-child{border-top:0}
.rf-meta{display:flex;flex-wrap:wrap;gap:.5em;align-items:baseline;font-size:.9em}
.rf-meta time,.rf-muted{color:var(--rf-muted)}
.rf-body p{margin:.35em 0;overflow-wrap:anywhere}
.rf-badge{font-size:.75em;padding:.05em .5em;border-radius:999px;border:1px solid var(--rf-border);color:var(--rf-muted)}
.rf-pending{opacity:.75}
.rf-empty{color:var(--rf-muted);margin:0 0 1em}
.rf-notice{padding:.6em .8em;border-radius:var(--rf-radius);border:1px solid var(--rf-border);margin:0 0 1em;background:var(--rf-surface)}
.rf-notice.ok{border-color:var(--rf-ok)}
.rf-notice.error{border-color:var(--rf-danger);color:var(--rf-danger)}
form.rf-form{display:grid;gap:.6em}
.rf-row{display:grid;grid-template-columns:1fr 1fr;gap:.6em}
@media (max-width:480px){.rf-row{grid-template-columns:1fr}}
label{display:grid;gap:.2em;font-size:.9em;color:var(--rf-muted)}
input,textarea,select{font:inherit;color:var(--rf-text);background:var(--rf-surface);
border:1px solid var(--rf-border);border-radius:var(--rf-radius);padding:.5em .65em;width:100%}
textarea{min-height:6em;resize:vertical}
input:focus,textarea:focus,select:focus{outline:2px solid var(--rf-accent);outline-offset:-1px}
button,.rf-button{font:inherit;cursor:pointer;background:var(--rf-accent);color:#fff;border:0;
border-radius:var(--rf-radius);padding:.5em 1em;text-decoration:none;display:inline-block}
button.rf-secondary{background:transparent;color:var(--rf-text);border:1px solid var(--rf-border)}
button.rf-danger{background:var(--rf-danger)}
button.rf-link{background:none;color:var(--rf-accent);padding:0;text-decoration:underline}
.rf-actions{display:flex;gap:1em;align-items:center;justify-content:space-between;flex-wrap:wrap}
.rf-actions small{color:var(--rf-muted)}
.rf-hp{position:absolute!important;left:-10000px!important;width:1px;height:1px;overflow:hidden}
.rf-footer{margin-top:1em;font-size:.85em;color:var(--rf-muted)}
.rf-inline{display:inline}
")

(defparameter *dark-vars*
  "--rf-accent:#58a6ff;--rf-text:#e6edf3;--rf-muted:#8d96a0;--rf-surface:#0d1117;--rf-border:#30363d;--rf-danger:#f85149;--rf-ok:#3fb950;color-scheme:dark")

(defparameter *page-css* "
body{background:#f6f8fa;padding:0 16px}
@media (prefers-color-scheme:dark){body{background:#010409}}
.page{max-width:56rem;margin:2rem auto;background:var(--rf-surface);border:1px solid var(--rf-border);
border-radius:12px;padding:1.5rem}
.page.narrow{max-width:30rem}
.page h1{font-size:1.4em;margin:0 0 1em}
.page h2{font-size:1.1em;margin:1.5em 0 .5em}
.page nav{display:flex;gap:1em;align-items:center;justify-content:space-between;margin:-.25rem 0 1.25rem;
font-size:.9em;flex-wrap:wrap}
table{width:100%;border-collapse:collapse;font-size:.9em}
th,td{text-align:left;padding:.5em .4em;border-top:1px solid var(--rf-border);vertical-align:top}
th{color:var(--rf-muted);font-weight:600}
td form{display:inline}
td .rf-actions{justify-content:flex-start;gap:.4em}
td button{padding:.2em .6em;font-size:.85em}
pre{background:var(--rf-bg);border:1px solid var(--rf-border);border-radius:var(--rf-radius);padding:.75em;
overflow:auto;font-size:.85em}
.grid2{display:grid;grid-template-columns:repeat(auto-fill,minmax(14rem,1fr));gap:.6em}
.preview{width:100%;border:1px dashed var(--rf-border);border-radius:var(--rf-radius);min-height:20rem}
.tabs{display:flex;gap:.75em;font-size:.9em;margin:.25em 0 .75em}
.tabs a.on{font-weight:700;text-decoration:none;color:var(--rf-text)}
.page h3{font-size:.95em;margin:.5em 0}
table.bars td{border:0;padding:.1em .4em;white-space:nowrap}
.bar{height:.7em;background:var(--rf-accent);border-radius:2px;min-width:2px}
")

;;; ------------------------------------------------------------------
;;; Themes

(defun safe-css-value (value)
  "Strip characters that could escape a CSS declaration."
  (and value (remove-if (lambda (c) (find c ";{}<>\\\"'`")) (substitute #\Space #\Newline value))))

;;; Theme values come from the admin form and are interpolated into a
;;; <style> element as raw text, so they're sanitised: SAFE-CSS-VALUE (above)
;;; strips characters that could end a declaration or a rule, and custom CSS
;;; has every "</" escaped so it can never close the <style> tag and start
;;; HTML (<\/style> is still valid CSS text but not an end tag).
(defun theme-value (site key)
  (let ((v (gethash key (getf site :theme))))
    (unless (blank-p v) v)))

(defun theme-css (site)
  "CSS custom properties (and custom CSS) for SITE's theme."
  (with-output-to-string (out)
    (let ((scheme (or (theme-value site "scheme") "light")))
      (cond ((string= scheme "dark") (format out ":root{~a}" *dark-vars*))
            ((string= scheme "auto")
             (format out ":root{color-scheme:light dark}@media (prefers-color-scheme:dark){:root{~a}}"
                     *dark-vars*))))
    (format out ":root{")
    (loop for (key . var) in '(("accent" . "--rf-accent") ("text" . "--rf-text")
                               ("muted" . "--rf-muted") ("background" . "--rf-bg")
                               ("surface" . "--rf-surface") ("border" . "--rf-border")
                               ("font" . "--rf-font") ("radius" . "--rf-radius"))
          for value = (theme-value site key)
          when value do (format out "~a:~a;" var (safe-css-value value)))
    (format out "}")
    (let ((custom (theme-value site "custom_css")))
      (when custom
        ;; Never let custom CSS close the <style> element.
        (write-string (cl-ppcre:regex-replace-all "(?i)</" custom "<\\\\/") out)))))

;;; ------------------------------------------------------------------
;;; Layout

;;; Why a macro rather than a function taking a body string? BODY is
;;; Spinneret code that must be expanded *inside* WITH-HTML-STRING to print
;;; into the same output, which only a macro can arrange. This is exactly
;;; the book's STANDARD-PAGE macro (ch. 2): the boilerplate lives in one
;;; place, and every page expands into a complete document.
;;; ,@(when extra-css …) splices in a third <style> only when given:
;;; WHEN returns NIL otherwise, and splicing NIL adds nothing.
(defmacro html-page ((&key title (css '*page-css*) extra-css body-class) &body body)
  "Render a complete HTML document and return it as a string."
  `(let ((*print-pretty* nil))
     (spinneret:with-html-string
       (:doctype)
       (:html :lang "en"
        (:head
         (:meta :charset "utf-8")
         (:meta :name "viewport" :content "width=device-width, initial-scale=1")
         (:meta :name "robots" :content "noindex")
         (:title ,title)
         (:style (:raw *base-css*))
         (:style (:raw ,css))
         ,@(when extra-css `((:style (:raw ,extra-css)))))
        (:body :class ,body-class ,@body)))))

;;; Comments are plain text. Blank lines become paragraphs, single newlines
;;; become <br>. Every LINE is printed by Spinneret, therefore escaped:
;;; "<script>" shows up literally. (The :span wrapper exists because a bare
;;; variable inside LOOP's DO clause is evaluated but not printed; only tag
;;; forms and direct children of tags emit output.)
(defun comment-body-html (body)
  (spinneret:with-html
    (:div.rf-body
     (dolist (para (render-body body))
       (:p (loop for (line . more) on para
                 do (progn (:span line) (when more (:br)))))))))

(defun notice-html (notice &optional (kind "ok"))
  (when notice
    (spinneret:with-html
      (:div :class (format nil "rf-notice ~a" kind) :role "status" notice))))

(defun simple-page (title message &key (kind "ok") link link-text)
  (html-page (:title title)
    (:main.page.narrow
     (:h1 title)
     (notice-html message kind)
     (when link (:p (:a :href link (or link-text "Continue")))))))

;;; After a POST we redirect with ?notice=check-email, and the page looks the
;;; message up here. Using fixed keys instead of putting the message itself
;;; in the URL means nobody can craft a link that makes our page display
;;; arbitrary text (a phishing/"content injection" trick).
(defparameter *notices*
  '(("check-email" . "Thanks! We've emailed you a link — your comment appears once you confirm your address.")
    ("posted" . "Your comment has been posted.")
    ("email-failed" . "Your comment was saved, but we couldn't send the confirmation email. Please try again later.")
    ("email-limit" . "Your comment was saved, but we've sent too many emails to that address recently. Try again in an hour.")
    ("signed-out" . "You've been signed out.")
    ("name-saved" . "Display name updated.")
    ("deleted" . "Comment deleted.")
    ("saved" . "Saved."))
  "Fixed messages selectable by the ?notice= parameter (never echo raw input).")

(defun notice-text (key)
  (cdr (assoc key *notices* :test #'equal)))
