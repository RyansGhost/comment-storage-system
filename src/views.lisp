;;;; views.lisp — HTML layout, CSS and site themes (Spinneret).
;;;;
;;;; Spinneret escapes every string it prints, so user content is always
;;;; safe to interpolate. Only CSS we generate ourselves goes through :RAW.

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
.rf-comment{padding:.75em 0;border-top:1px solid var(--rf-border)}
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
