;;;; admin.lisp — the tiny admin GUI: sites, themes and moderation.
;;;;
;;;; A single administrator authenticates with ADMIN_PASSWORD. The admin
;;;; session cookie is scoped to /admin with SameSite=Strict.

(in-package #:rf-comments)

(defun admin-session-p ()
  (and (find-session (ht:cookie-in +admin-cookie+) "admin") t))

(defun @admin (next)
  (cond ((null *admin-password*)
         (error-page 404 "Not found" "The admin interface is disabled (ADMIN_PASSWORD is not set)."))
        ((admin-session-p) (funcall next))
        (t (redirect-to "/admin/login"))))

(defmacro admin-page ((title) &body body)
  "Admin layout. Headers come from the DEFPAGE/DEFACTION route macros."
  `(html-page (:title (format nil "~a · admin" ,title))
     (:main.page
      (:nav (:span (:a :href "/admin" (:strong "Comments admin")) " · "
                   (:a :href "/admin/sites/new" "New site"))
            (:form.rf-inline :method "post" :action "/admin/logout"
                             (:button.rf-secondary :type "submit" "Log out")))
      ,@body)))

;;; ------------------------------------------------------------------
;;; Login

(defun admin-login-page (&optional error (status 200))
  (respond
   (html-page (:title "Admin sign in")
     (:main.page.narrow
      (:h1 "Admin sign in")
      (notice-html error "error")
      (:form.rf-form :method "post" :action "/admin/login"
       (:label "Password" (:input :type "password" :name "password" :required t :autofocus t
                                  :autocomplete "current-password"))
       (:div (:button :type "submit" "Sign in")))))
   :status status))

(defpage admin-login ("/admin/login") ()
  (cond ((null *admin-password*)
         (error-page 404 "Not found" "The admin interface is disabled (ADMIN_PASSWORD is not set)."))
        ((admin-session-p) (redirect-to "/admin"))
        (t (admin-login-page))))

(defaction admin-login-post ("/admin/login") (&post password)
  (cond ((null *admin-password*) (error-page 404 "Not found" "Admin is disabled."))
        ((rate-limited-p (list :admin-login (client-ip)) 5 60)
         (admin-login-page "Too many attempts; wait a minute." 429))
        ((constant-time-string= password *admin-password*)
         (set-cookie +admin-cookie+ (create-session "admin" :ttl *admin-session-ttl*)
                     :max-age *admin-session-ttl* :path "/admin" :same-site "Strict")
         (redirect-to "/admin"))
        (t (admin-login-page "Wrong password." 401))))

(defaction admin-logout ("/admin/logout") ()
  (delete-session (ht:cookie-in +admin-cookie+))
  (clear-cookie +admin-cookie+ :path "/admin" :same-site "Strict")
  (redirect-to "/admin/login"))

;;; ------------------------------------------------------------------
;;; Dashboard: sites + moderation queue

(defun status-button (id action label &optional (class ""))
  (spinneret:with-html
    (:form :method "post" :action (format nil "/admin/comments/~d/~a" id action)
           (:button :type "submit" :class class label))))

(defpage admin-home ("/admin" :decorators (@admin @no-cache)) (&get status)
  (let* ((status (and (member status '("pending" "published" "hidden") :test #'equal) status))
         (sites (list-sites))
         (status-counts (site-status-counts))
         (comments (recent-comments :status status :limit 200)))
    (flet ((site-count (site key)
             (let ((row (find (getf site :id) status-counts :key (lambda (r) (getf r :id)))))
               (princ-to-string (or (getf row key) 0)))))
    (admin-page ("Dashboard")
      (:h1 "Sites")
      (if (null sites)
          (:p.rf-empty "No sites yet. " (:a :href "/admin/sites/new" "Add the first one") ".")
          (:table
           (:thead (:tr (:th "Key") (:th "Name") (:th "Allowed origins") (:th "Enabled")
                        (:th "Published") (:th "Pending") (:th "Hidden") (:th "")))
           (:tbody
            (dolist (s sites)
              (:tr (:td (:code (getf s :key)))
                   (:td (getf s :name))
                   (:td (format nil "~{~a~^, ~}" (getf s :origins)))
                   (:td (if (getf s :enabled) "yes" "no"))
                   (:td (site-count s :published))
                   (:td (site-count s :pending))
                   (:td (site-count s :hidden))
                   (:td (:a :href (format nil "/admin/sites/~d" (getf s :id)) "Edit")))))))
      (stats-section)
      (:h2 "Comments")
      (:div.tabs
       (loop for (label value) in '(("All" nil) ("Pending" "pending")
                                    ("Published" "published") ("Hidden" "hidden"))
             do (:a :class (if (equal value status) "on" "")
                    :href (if value (format nil "/admin?status=~a" value) "/admin")
                    label)))
      (if (null comments)
          (:p.rf-empty "Nothing here.")
          (:table
           (:thead (:tr (:th "Date") (:th "Site / page") (:th "Author") (:th "Comment")
                        (:th "Status") (:th "")))
           (:tbody
            (dolist (c comments)
              (:tr
               (:td (human-date (getf c :created-at)))
               (:td (:code (getf c :site-key)) (:br)
                    (:a :href (getf c :link-url) :target "_blank" :rel "noopener"
                        (truncate-string (getf c :link-url) 60)))
               (:td (getf c :display-name) (:br)
                    (:small.rf-muted (getf c :email)
                                     (if (getf c :verified-at) " ✓" " (unverified)")))
               (:td (truncate-string (getf c :body) 240))
               (:td (getf c :status))
               (:td (:div.rf-actions
                     (unless (string= (getf c :status) "published")
                       (status-button (getf c :id) "publish" "Publish"))
                     (unless (string= (getf c :status) "hidden")
                       (status-button (getf c :id) "hide" "Hide" "rf-secondary"))
                     (status-button (getf c :id) "delete" "Delete" "rf-danger"))))))))
      (:h2 "Activity")
      (let ((entries (recent-moderation 50)))
        (if (null entries)
            (:p.rf-empty "No moderation activity yet.")
            (:table
             (:thead (:tr (:th "When") (:th "Action") (:th "By") (:th "Comment")))
             (:tbody
              (dolist (e entries)
                (:tr (:td (getf e :created-at))
                     (:td (getf e :action))
                     (:td (getf e :actor))
                     (:td (format nil "#~a " (getf e :comment-id))
                          (:small.rf-muted (getf e :summary)))))))))))))

(defun stats-section ()
  "Activity charts, aggregated by SQLite (see the Aggregates section of db.lisp)."
  (let* ((days (comments-per-day 30))
         (peak (max 1 (reduce #'max days :key (lambda (d) (getf d :n)) :initial-value 0)))
         (top (top-threads 10)))
    (spinneret:with-html
      (:h2 "Stats")
      (:div.grid2
       (:div
        (:h3.rf-muted "Comments per day (30 days)")
        (if (null days)
            (:p.rf-empty "No comments in the last 30 days.")
            (:table.bars
             (:tbody
              (dolist (d days)
                (:tr (:td (:small (getf d :day)))
                     (:td :style "width:100%"
                          (:div.bar :style (format nil "width:~,1f%" (* 100 (/ (getf d :n) peak)))))
                     (:td (princ-to-string (getf d :n)))))))))
       (:div
        (:h3.rf-muted "Most-commented threads")
        (if (null top)
            (:p.rf-empty "No published comments yet.")
            (:ol
             (dolist (th top)
               (:li (:a :href (getf th :url) :target "_blank" :rel "noopener"
                        (if (blank-p (getf th :title)) (getf th :url) (getf th :title)))
                    (:small.rf-muted (format nil " · ~a · ~d" (getf th :site-key)
                                             (getf th :n))))))))))))

(defaction admin-comment-action ("/admin/comments/:id/:action" :decorators (@admin))
    (&path (id 'integer))
  (let ((comment (comment-by-id id)))
    (when comment
      (cond ((string= action "publish") (publish-comment comment :admin))
            ((string= action "hide") (hide-comment comment :admin))
            ((string= action "delete") (remove-comment comment :admin)))))
  (redirect-to (let ((ref (ht:header-in* :referer)))
                 (if (and ref (equal (url-origin ref) (url-origin *public-url*)))
                     (subseq ref (length (url-origin ref)))
                     "/admin"))))

;;; ------------------------------------------------------------------
;;; Site editor

(defun theme-placeholder (key)
  (cdr (assoc key '(("accent" . "#2563eb") ("text" . "#1f2328") ("muted" . "#656d76")
                    ("background" . "transparent") ("surface" . "#ffffff")
                    ("border" . "#d0d7de") ("font" . "system-ui, sans-serif")
                    ("radius" . "8px"))
              :test #'string=)))

(defun embed-snippet (key)
  (format nil "<div id=\"rf-comments\"></div>~%<script src=\"~a/embed.js\" data-site=\"~a\" async></script>"
          *public-url* key))

(defun site-form-page (&key site values error (status 200))
  "SITE is the stored row (NIL when creating); VALUES the submitted form plist."
  (let* ((id (getf site :id))
         (v (or values
                (and site
                     (list :key (getf site :key) :name (getf site :name)
                           :origins (format nil "~{~a~%~}" (getf site :origins))
                           :enabled (getf site :enabled) :theme (getf site :theme)))
                (list :enabled t :theme (make-hash-table :test #'equal))))
         (theme (getf v :theme)))
    (respond
     (admin-page ((if site (getf site :name) "New site"))
       (:h1 (if site (format nil "Edit ~a" (getf site :name)) "New site"))
       (notice-html error "error")
       (:form.rf-form :method "post" :action (if id (format nil "/admin/sites/~d" id) "/admin/sites")
        (:div.rf-row
         (:label "Key (used in the embed code)"
                 (:input :name "key" :required t :pattern "[a-z0-9][a-z0-9-]*" :maxlength 40
                         :placeholder "blog" :value (getf v :key)))
         (:label "Name" (:input :name "name" :required t :maxlength 100
                                :placeholder "Ryan's blog" :value (getf v :name))))
        (:label "Allowed origins — one per line; pages on these origins may embed comments"
                (:textarea :name "origins" :rows 3 :placeholder "https://blog.ryanfleck.ca"
                           (or (getf v :origins) "")))
        (:label :style "display:flex;gap:.5em;align-items:center"
                (:input :type "checkbox" :name "enabled" :value "1" :checked (getf v :enabled)
                        :style "width:auto")
                "Enabled")
        (:h2 "Style")
        (:div.grid2
         (:label "Colour scheme"
                 (:select :name "theme_scheme"
                   (dolist (opt '("light" "dark" "auto"))
                     (:option :value opt :selected (equal opt (or (gethash "scheme" theme) "light"))
                              opt))))
         (loop for (key . label) in *theme-keys*
               unless (string= key "custom_css")
                 do (:label label
                            (:input :name (format nil "theme_~a" key) :maxlength 200
                                    :placeholder (theme-placeholder key)
                                    :value (gethash key theme)))))
        (:label "Custom CSS (applied inside the comment frame)"
                (:textarea :name "theme_custom_css" :rows 4 :style "font-family:monospace"
                           :placeholder ".rf-comment { padding: 1em 0 }"
                           (or (gethash "custom_css" theme) "")))
        (:div.rf-actions (:span) (:button :type "submit" (if site "Save" "Create site"))))
       (when site
         (:h2 "Embed code")
         (:p.rf-muted "Paste this where comments should appear. Optional attributes: "
                      "data-page-id (a stable thread id that survives URL changes), "
                      "data-page-url (canonical URL), data-page-title.")
         (:pre (embed-snippet (getf site :key)))
         (threads-section site)
         (when (getf site :origins)
           (:h2 "Preview")
           (:iframe.preview
            :title "Preview"
            :src (thread-path (getf site :key)
                              (format nil "~a/" (first (getf site :origins))) "Preview")))
         (:h2 "Danger zone")
         (:form :method "post" :action (format nil "/admin/sites/~d/delete" id)
                (:button.rf-danger :type "submit" "Delete site and all its comments"))))
     :status status)))

(defun threads-section (site)
  (let ((threads (site-threads (getf site :id))))
    (spinneret:with-html
      (:h2 "Threads")
      (if (null threads)
          (:p.rf-empty "No threads yet.")
          (progn
            (:p.rf-muted "A thread is keyed by its page id, or by its URL when the embed has "
                         "no data-page-id. Moving a thread onto a key that another thread "
                         "already uses merges the two.")
            (:table
             (:thead (:tr (:th "Key / URL") (:th "Comments") (:th "Move to")))
             (:tbody
              (dolist (th threads)
                (:tr
                 (:td (:code (getf th :page-key)) (:br)
                      (:a :href (getf th :url) :target "_blank" :rel "noopener"
                          (if (blank-p (getf th :title)) (getf th :url) (getf th :title))))
                 (:td (princ-to-string (getf th :comment-count)))
                 (:td (:form.rf-form :method "post"
                                     :action (format nil "/admin/threads/~d/move" (getf th :id))
                       (:input :name "key" :value (getf th :page-key) :maxlength 200
                               :aria-label "Key")
                       (:input :name "url" :value (getf th :url) :required t
                               :aria-label "URL")
                       (:button.rf-secondary :type "submit" "Move"))))))))))))

(defun clean-thread-key (key)
  "A page id, or a URL (canonicalised)."
  (let ((url (canonical-page-url key)))
    (or url (clean-page-id key))))

(defaction admin-thread-move ("/admin/threads/:id/move" :decorators (@admin))
    (&post key url &path (id 'integer))
  (let* ((thread (thread-by-id id))
         (site (and thread (site-by-id (getf thread :site-id)))))
    (if (null thread)
        (error-page 404 "Not found" "No such thread.")
        (let ((new-url (canonical-page-url url)))
          (flet ((fail (message) (site-form-page :site site :error message :status 422)))
            (cond ((or (null new-url) (not (site-allows-page-p site new-url)))
                   (fail "The URL must be on one of this site's allowed origins."))
                  (t
                   (with-valid-inputs ((new-key clean-thread-key
                                                (if (blank-p key) new-url key)))
                       (:on-error (message) (fail message))
                     (move-thread id new-key new-url)
                     (redirect-to (format nil "/admin/sites/~d" (getf site :id)))))))))))

(defun site-form-values ()
  (let ((theme (make-hash-table :test #'equal)))
    (dolist (key (cons "scheme" (mapcar #'car *theme-keys*)))
      (setf (gethash key theme) (or (ht:post-parameter (format nil "theme_~a" key)) "")))
    (list :key (string-downcase (trim (ht:post-parameter "key")))
          :name (trim (ht:post-parameter "name"))
          :origins (or (ht:post-parameter "origins") "")
          :enabled (and (ht:post-parameter "enabled") t)
          :theme theme)))

(defun validate-site-values (v &optional existing-id)
  "Returns an error message, or NIL if V is valid."
  (multiple-value-bind (origins invalid) (parse-origins (getf v :origins))
    (declare (ignore origins))
    (let ((clash (site-by-key (getf v :key))))
      (cond ((not (valid-site-key-p (getf v :key)))
             "Key must be lowercase letters, digits and dashes.")
            ((and clash (not (eql (getf clash :id) existing-id)))
             "Another site already uses that key.")
            ((blank-p (getf v :name)) "Name is required.")
            ((> (length (getf v :name)) 100) "Name is too long.")
            (invalid (format nil "Not valid origins: ~{~a~^, ~}" invalid))))))

(defun save-site (v &optional id)
  (let ((args (list :key (getf v :key) :name (getf v :name) :origins (getf v :origins)
                    :enabled (getf v :enabled) :theme (getf v :theme))))
    (if id
        (progn (apply #'update-site id args) id)
        (apply #'create-site args))))

(defpage admin-site-new ("/admin/sites/new" :decorators (@admin @no-cache)) ()
  (site-form-page))

(defaction admin-site-create ("/admin/sites" :decorators (@admin)) ()
  (let* ((v (site-form-values))
         (error (validate-site-values v)))
    (if error
        (site-form-page :values v :error error :status 422)
        (redirect-to (format nil "/admin/sites/~d" (save-site v))))))

(defpage admin-site-edit ("/admin/sites/:id" :decorators (@admin @no-cache))
    (&path (id 'integer))
  (let ((site (site-by-id id)))
    (if site
        (site-form-page :site site)
        (error-page 404 "Not found" "No such site."))))

(defaction admin-site-update ("/admin/sites/:id" :decorators (@admin))
    (&path (id 'integer))
  (let ((site (site-by-id id)))
    (if (null site)
        (error-page 404 "Not found" "No such site.")
        (let* ((v (site-form-values))
               (error (validate-site-values v id)))
          (if error
              (site-form-page :site site :values v :error error :status 422)
              (progn (save-site v id)
                     (redirect-to (format nil "/admin/sites/~d" id))))))))

(defaction admin-site-delete ("/admin/sites/:id/delete" :decorators (@admin))
    (&path (id 'integer))
  (delete-site id)
  (redirect-to "/admin"))
