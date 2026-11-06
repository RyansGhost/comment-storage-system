;;;; db.lisp — SQLite connection, migrations and the data model.
;;;;
;;;; One connection, guarded by a recursive lock: Hunchentoot serves each
;;;; request on its own thread, and a personal comment box never needs
;;;; more than one writer. Rows come back as plists with keyword keys,
;;;; e.g. (:id 1 :email "a@b.c" ...).

(in-package #:rf-comments)

(defvar *db* nil "The open SQLITE:SQLITE-HANDLE.")
(defvar *db-lock* (bt:make-recursive-lock "rf-comments db"))

(defmacro with-db (() &body body)
  "Run BODY holding the database lock."
  `(bt:with-recursive-lock-held (*db-lock*)
     (unless *db* (error "Database is not open; call (rf-comments:db-open) first."))
     ,@body))

(defmacro with-transaction (() &body body)
  `(with-db () (sqlite:with-transaction *db* ,@body)))

(defun column-keyword (name)
  (intern (string-upcase (substitute #\- #\_ name)) :keyword))

(defun query (sql &rest params)
  "Run SQL with positional PARAMS (?) and return all rows as plists."
  (with-db ()
    (let ((stmt (sqlite:prepare-statement *db* sql)))
      (unwind-protect
           (progn
             (loop for p in params for i from 1
                   do (sqlite:bind-parameter stmt i (if (eq p t) 1 p)))
             (let ((keys (mapcar #'column-keyword (sqlite:statement-column-names stmt))))
               (loop while (sqlite:step-statement stmt)
                     collect (loop for k in keys for i from 0
                                   collect k
                                   collect (sqlite:statement-column-value stmt i)))))
        (sqlite:finalize-statement stmt)))))

(defun query-one (sql &rest params)
  (first (apply #'query sql params)))

(defun exec (sql &rest params)
  "Run a statement. Returns (values last-insert-rowid changes)."
  (with-db ()
    (apply #'sqlite:execute-non-query *db* sql
           (mapcar (lambda (p) (if (eq p t) 1 p)) params))
    (values (sqlite:last-insert-rowid *db*)
            (sqlite:execute-single *db* "SELECT changes()"))))

;;; ------------------------------------------------------------------
;;; Migrations: append new entries; never edit an applied one.

(defparameter *migrations*
  '((1
     "CREATE TABLE settings (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL)"
     "CREATE TABLE sites (
        id         INTEGER PRIMARY KEY,
        key        TEXT NOT NULL UNIQUE,
        name       TEXT NOT NULL,
        origins    TEXT NOT NULL DEFAULT '',
        enabled    INTEGER NOT NULL DEFAULT 1,
        theme      TEXT NOT NULL DEFAULT '{}',
        created_at TEXT NOT NULL)"
     "CREATE TABLE users (
        id           INTEGER PRIMARY KEY,
        email        TEXT NOT NULL UNIQUE,
        display_name TEXT NOT NULL,
        verified_at  TEXT,
        created_at   TEXT NOT NULL)"
     "CREATE TABLE comments (
        id           INTEGER PRIMARY KEY,
        site_id      INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
        user_id      INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        page_url     TEXT NOT NULL,
        page_title   TEXT NOT NULL DEFAULT '',
        body         TEXT NOT NULL,
        status       TEXT NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending','published','hidden')),
        ip_hash      TEXT,
        created_at   TEXT NOT NULL,
        published_at TEXT)"
     "CREATE INDEX comments_page ON comments(site_id, page_url, status, created_at)"
     "CREATE INDEX comments_user ON comments(user_id, created_at)"
     "CREATE TABLE tokens (
        id         INTEGER PRIMARY KEY,
        token_hash TEXT NOT NULL UNIQUE,
        user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        comment_id INTEGER REFERENCES comments(id) ON DELETE CASCADE,
        purpose    TEXT NOT NULL CHECK (purpose IN ('verify','login')),
        expires_at TEXT NOT NULL,
        used_at    TEXT,
        created_at TEXT NOT NULL)"
     "CREATE INDEX tokens_user ON tokens(user_id, created_at)"
     "CREATE TABLE sessions (
        token_hash TEXT PRIMARY KEY,
        kind       TEXT NOT NULL CHECK (kind IN ('user','admin')),
        user_id    INTEGER REFERENCES users(id) ON DELETE CASCADE,
        created_at TEXT NOT NULL,
        expires_at TEXT NOT NULL)")
    (2
     ;; Audit trail written by the observers in events.lisp. No foreign key:
     ;; entries outlive the comments they describe.
     "CREATE TABLE moderation_log (
        id         INTEGER PRIMARY KEY,
        comment_id INTEGER,
        action     TEXT NOT NULL,
        actor      TEXT NOT NULL,
        summary    TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL)")
    (3
     ;; Stable thread identity ("On natural IDs"): a thread is keyed by the
     ;; embed's data-page-id, or by its canonical URL when there is none.
     ;; comments.page_url keeps the URL the comment was posted from.
     "CREATE TABLE threads (
        id         INTEGER PRIMARY KEY,
        site_id    INTEGER NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
        page_key   TEXT NOT NULL,
        url        TEXT NOT NULL,
        title      TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL,
        UNIQUE (site_id, page_key))"
     "INSERT INTO threads (site_id, page_key, url, title, created_at)
        SELECT site_id, page_url, page_url, max(page_title), min(created_at)
        FROM comments GROUP BY site_id, page_url"
     "ALTER TABLE comments ADD COLUMN thread_id INTEGER REFERENCES threads(id) ON DELETE CASCADE"
     "UPDATE comments SET thread_id =
        (SELECT t.id FROM threads t
         WHERE t.site_id = comments.site_id AND t.page_key = comments.page_url)"
     "CREATE INDEX comments_thread ON comments(thread_id, status, created_at)")))

(defun migrate ()
  (exec "CREATE TABLE IF NOT EXISTS schema_migrations (
           version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)")
  (dolist (migration *migrations*)
    (destructuring-bind (version &rest statements) migration
      (unless (query-one "SELECT version FROM schema_migrations WHERE version = ?" version)
        (with-transaction ()
          (dolist (sql statements) (exec sql))
          (exec "INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)"
                version (iso-time)))
        (format t "~&;; applied migration ~d~%" version)))))

(defun db-open (&optional (path *db-path*))
  "Open (creating if needed) the database at PATH and run migrations."
  (bt:with-recursive-lock-held (*db-lock*)
    (when *db* (db-close))
    (unless (string= path ":memory:")
      (ensure-directories-exist (merge-pathnames path)))
    (setf *db* (sqlite:connect (if (string= path ":memory:")
                                   path
                                   (namestring (merge-pathnames path)))))
    (sqlite:set-busy-timeout *db* 5000)
    (sqlite:execute-single *db* "PRAGMA journal_mode = WAL")
    (sqlite:execute-non-query *db* "PRAGMA foreign_keys = ON")
    (sqlite:execute-non-query *db* "PRAGMA synchronous = NORMAL")
    (migrate)
    *db*))

(defun db-close ()
  (bt:with-recursive-lock-held (*db-lock*)
    (when *db*
      (ignore-errors (sqlite:disconnect *db*))
      (setf *db* nil))))

;;; ------------------------------------------------------------------
;;; Settings

(defun setting (key)
  (getf (query-one "SELECT value FROM settings WHERE key = ?" key) :value))

(defun (setf setting) (value key)
  (exec "INSERT INTO settings (key, value) VALUES (?, ?)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value" key value)
  value)

(defun ip-salt ()
  (or (setting "ip_salt")
      (setf (setting "ip_salt") (random-token 16))))

(defun hash-ip (ip)
  (when ip
    (subseq (ironclad:byte-array-to-hex-string (hmac-sha256 (ip-salt) ip)) 0 16)))

;;; ------------------------------------------------------------------
;;; Sites

(defparameter *theme-keys*
  '(("accent" . "Accent colour")
    ("text" . "Text colour")
    ("muted" . "Muted text colour")
    ("background" . "Background")
    ("surface" . "Input/card background")
    ("border" . "Border colour")
    ("font" . "Font family")
    ("radius" . "Corner radius")
    ("custom_css" . "Custom CSS"))
  "Configurable theme properties, in the order the admin form shows them.")

(defun decode-site (row)
  (when row
    (let ((theme (ignore-errors (jzon:parse (getf row :theme)))))
      (setf (getf row :theme) (if (hash-table-p theme) theme (make-hash-table :test #'equal))
            (getf row :origins) (parse-origins (getf row :origins))
            (getf row :enabled) (eql (getf row :enabled) 1))
      row)))

(defun encode-theme (theme)
  "THEME is an alist or hash table of string → string; blank values dropped."
  (let ((h (make-hash-table :test #'equal)))
    (flet ((add (k v) (unless (blank-p v) (setf (gethash k h) (trim v)))))
      (if (hash-table-p theme)
          (maphash #'add theme)
          (loop for (k . v) in theme do (add k v))))
    (jzon:stringify h)))

(defun site-by-key (key)
  (decode-site (query-one "SELECT * FROM sites WHERE key = ?" key)))

(defun site-by-id (id)
  (decode-site (query-one "SELECT * FROM sites WHERE id = ?" id)))

(defun list-sites ()
  (mapcar #'decode-site
          (query "SELECT s.*, (SELECT count(*) FROM comments c WHERE c.site_id = s.id) AS comment_count
                  FROM sites s ORDER BY s.key")))

(defun create-site (&key key name origins (enabled t) theme)
  "ORIGINS is a list of origin strings (or a string to parse)."
  (values
   (exec "INSERT INTO sites (key, name, origins, enabled, theme, created_at)
          VALUES (?, ?, ?, ?, ?, ?)"
         key name
         (format nil "~{~a~^~%~}" (if (stringp origins) (parse-origins origins) origins))
         (if enabled 1 0) (encode-theme theme) (iso-time))))

(defun update-site (id &key key name origins enabled theme)
  (exec "UPDATE sites SET key = ?, name = ?, origins = ?, enabled = ?, theme = ? WHERE id = ?"
        key name
        (format nil "~{~a~^~%~}" (if (stringp origins) (parse-origins origins) origins))
        (if enabled 1 0) (encode-theme theme) id))

(defun delete-site (id)
  (exec "DELETE FROM sites WHERE id = ?" id))

(defun site-allows-page-p (site page-url)
  (let ((origin (url-origin page-url)))
    (and origin (member origin (getf site :origins) :test #'string=) t)))

;;; ------------------------------------------------------------------
;;; Users

(defun user-by-id (id) (query-one "SELECT * FROM users WHERE id = ?" id))
(defun user-by-email (email) (query-one "SELECT * FROM users WHERE email = ?" email))

(defun find-or-create-user (email display-name)
  "Return the user row for EMAIL, creating it if needed. The display name of
an already verified user is never changed by an anonymous submission."
  (with-transaction ()
    (let ((user (user-by-email email)))
      (cond ((null user)
             (user-by-id
              (exec "INSERT INTO users (email, display_name, created_at) VALUES (?, ?, ?)"
                    email display-name (iso-time))))
            ((and (null (getf user :verified-at))
                  (string/= display-name (getf user :display-name)))
             (exec "UPDATE users SET display_name = ? WHERE id = ?" display-name (getf user :id))
             (user-by-id (getf user :id)))
            (t user)))))

(defun set-user-name (user-id name)
  (exec "UPDATE users SET display_name = ? WHERE id = ?" name user-id))

(defun mark-user-verified (user-id)
  (exec "UPDATE users SET verified_at = coalesce(verified_at, ?) WHERE id = ?"
        (iso-time) user-id))

;;; ------------------------------------------------------------------
;;; Comments

(defun create-comment (&key site-id thread-id user-id page-url (page-title "") body
                         (status "pending") ip-hash)
  (let ((now (iso-time)))
    (values
     (exec "INSERT INTO comments (site_id, thread_id, user_id, page_url, page_title, body,
                                  status, ip_hash, created_at, published_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
           site-id thread-id user-id page-url page-title body status ip-hash now
           (when (string= status "published") now)))))

;;; LINK_URL is where a comment lives now: its thread's current URL, which
;;; can differ from PAGE_URL (where it was posted) after a page moves.

(defun comment-by-id (id)
  (query-one "SELECT c.*, u.display_name, u.email, s.key AS site_key,
                     coalesce(t.url, c.page_url) AS link_url
              FROM comments c JOIN users u ON u.id = c.user_id
              JOIN sites s ON s.id = c.site_id
              LEFT JOIN threads t ON t.id = c.thread_id WHERE c.id = ?" id))

(defun page-comments (thread-id &key viewer-id)
  "Published comments in a thread, plus the viewer's own pending ones."
  (query "SELECT c.id, c.body, c.status, c.created_at, c.user_id, u.display_name
          FROM comments c JOIN users u ON u.id = c.user_id
          WHERE c.thread_id = ?
            AND (c.status = 'published' OR (c.status = 'pending' AND c.user_id = ?))
          ORDER BY c.created_at, c.id"
         (or thread-id -1) (or viewer-id -1)))

(defun user-comments (user-id)
  (query "SELECT c.*, s.key AS site_key, s.name AS site_name,
                 coalesce(t.url, c.page_url) AS link_url
          FROM comments c JOIN sites s ON s.id = c.site_id
          LEFT JOIN threads t ON t.id = c.thread_id
          WHERE c.user_id = ? ORDER BY c.created_at DESC, c.id DESC" user-id))

(defun recent-comments (&key status (limit 100))
  (apply #'query
         (format nil "SELECT c.*, u.display_name, u.email, u.verified_at, s.key AS site_key,
                             coalesce(t.url, c.page_url) AS link_url
                      FROM comments c JOIN users u ON u.id = c.user_id
                      JOIN sites s ON s.id = c.site_id
                      LEFT JOIN threads t ON t.id = c.thread_id
                      ~:[~;WHERE c.status = ?~]
                      ORDER BY c.created_at DESC, c.id DESC LIMIT ~d"
                 status limit)
         (when status (list status))))

(defun set-comment-status (id status)
  (exec "UPDATE comments SET status = ?,
           published_at = CASE WHEN ? = 'published' THEN coalesce(published_at, ?)
                               ELSE published_at END
         WHERE id = ?" status status (iso-time) id))

(defun delete-comment (id)
  (exec "DELETE FROM comments WHERE id = ?" id))

;;; ------------------------------------------------------------------
;;; Threads

(defun thread-by-key (site-id page-key)
  (query-one "SELECT * FROM threads WHERE site_id = ? AND page_key = ?" site-id page-key))

(defun thread-by-id (id)
  (query-one "SELECT * FROM threads WHERE id = ?" id))

(defun ensure-thread (site-id page-key url &optional (title ""))
  "Return the thread for PAGE-KEY, creating it if needed. A thread keyed by
a page id follows its page: a different URL or title is recorded."
  (with-transaction ()
    (let ((thread (thread-by-key site-id page-key)))
      (cond ((null thread)
             (thread-by-id
              (exec "INSERT INTO threads (site_id, page_key, url, title, created_at)
                     VALUES (?, ?, ?, ?, ?)" site-id page-key url (or title "") (iso-time))))
            ((or (string/= url (getf thread :url))
                 (and (not (blank-p title)) (string/= title (getf thread :title))))
             (exec "UPDATE threads SET url = ?, title = CASE WHEN ? = '' THEN title ELSE ? END
                    WHERE id = ?" url (or title "") (or title "") (getf thread :id))
             (thread-by-id (getf thread :id)))
            (t thread)))))

(defun site-threads (site-id)
  (query "SELECT t.*, (SELECT count(*) FROM comments c WHERE c.thread_id = t.id) AS comment_count
          FROM threads t WHERE t.site_id = ? ORDER BY t.created_at DESC, t.id DESC" site-id))

(defun move-thread (thread-id new-key new-url)
  "Re-key and/or re-point a thread. If another thread of the same site
already has NEW-KEY, merge into it: its comments move there and this
thread is deleted. Returns the surviving thread's id."
  (with-transaction ()
    (let* ((thread (thread-by-id thread-id))
           (target (thread-by-key (getf thread :site-id) new-key)))
      (if (and target (/= (getf target :id) thread-id))
          (progn
            (exec "UPDATE comments SET thread_id = ? WHERE thread_id = ?" (getf target :id) thread-id)
            (exec "UPDATE threads SET url = ? WHERE id = ?" new-url (getf target :id))
            (exec "DELETE FROM threads WHERE id = ?" thread-id)
            (getf target :id))
          (progn
            (exec "UPDATE threads SET page_key = ?, url = ? WHERE id = ?" new-key new-url thread-id)
            thread-id)))))

;;; ------------------------------------------------------------------
;;; Email tokens (single use, hashed at rest)

(defun issue-token (user-id purpose &key comment-id (ttl *token-ttl*))
  (let ((raw (random-token)))
    (exec "INSERT INTO tokens (token_hash, user_id, comment_id, purpose, expires_at, created_at)
           VALUES (?, ?, ?, ?, ?, ?)"
          (sha256-hex raw) user-id comment-id purpose (iso-in ttl) (iso-time))
    raw))

(defun peek-token (raw purpose)
  "The valid (unused, unexpired) token row for RAW, without consuming it."
  (when (and (stringp raw) (<= 1 (length raw) 200))
    (query-one "SELECT * FROM tokens WHERE token_hash = ? AND purpose = ?
                AND used_at IS NULL AND expires_at > ?"
               (sha256-hex raw) purpose (iso-time))))

(defun consume-token (raw purpose)
  "Atomically mark the token used. Returns the token row, or NIL."
  (with-transaction ()
    (let ((token (peek-token raw purpose)))
      (when token
        (exec "UPDATE tokens SET used_at = ? WHERE id = ?" (iso-time) (getf token :id))
        token))))

(defun recent-email-count (user-id &optional (seconds 3600))
  (getf (query-one "SELECT count(*) AS n FROM tokens WHERE user_id = ? AND created_at > ?"
                   user-id (iso-in (- seconds)))
        :n))

;;; ------------------------------------------------------------------
;;; Sessions (hashed at rest)

(defun create-session (kind &key user-id (ttl *session-ttl*))
  (let ((raw (random-token)))
    (exec "INSERT INTO sessions (token_hash, kind, user_id, created_at, expires_at)
           VALUES (?, ?, ?, ?, ?)"
          (sha256-hex raw) kind user-id (iso-time) (iso-in ttl))
    raw))

(defun find-session (raw kind)
  (when (and (stringp raw) (<= 1 (length raw) 200))
    (query-one "SELECT * FROM sessions WHERE token_hash = ? AND kind = ? AND expires_at > ?"
               (sha256-hex raw) kind (iso-time))))

(defun delete-session (raw)
  (when raw (exec "DELETE FROM sessions WHERE token_hash = ?" (sha256-hex raw))))

(defun purge-expired ()
  "Remove expired sessions and stale tokens. Called opportunistically."
  (let ((now (iso-time)))
    (exec "DELETE FROM sessions WHERE expires_at <= ?" now)
    (exec "DELETE FROM tokens WHERE expires_at <= ?" (iso-in (* -30 24 60 60)))))
