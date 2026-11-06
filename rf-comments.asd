;;;; rf-comments.asd — a tiny multi-site comment service.

(asdf:defsystem "rf-comments"
  :description "Tiny self-hosted comment service for ryanfleck.ca subdomains."
  :author "Ryan Fleck <dev@ryanfleck.ca>"
  :version "0.1.0"
  :depends-on ("hunchentoot"
               "easy-routes"
               "sqlite"
               "spinneret"
               "com.inuoe.jzon"
               "ironclad"
               "dexador"
               "cl-ppcre"
               "quri"
               "bordeaux-threads"
               "babel"
               "alexandria"
               "flexi-streams"
               "sb-posix"
               "uiop")
  :serial t
  :components ((:module "src"
                :components ((:file "package")
                             (:file "config")
                             (:file "util")
                             (:file "db")
                             (:file "email")
                             (:file "events")
                             (:file "avatars")
                             (:file "views")
                             (:file "routes")
                             (:file "web")
                             (:file "admin")
                             (:file "repl")
                             (:file "main")))
               (:module "static"
                :components ((:static-file "embed.js")
                             (:static-file "thread.js")
                             (:static-file "count.js"))))
  :in-order-to ((test-op (test-op "rf-comments/tests"))))

(asdf:defsystem "rf-comments/tests"
  :description "FiveAM test-suite for rf-comments."
  :depends-on ("rf-comments" "fiveam" "dexador" "cl-cookie" "slynk")
  :serial t
  :components ((:module "tests"
                :components ((:file "package")
                             (:file "unit")
                             (:file "sigv4")
                             (:file "integration"))))
  :perform (test-op (o c)
             (unless (symbol-call :fiveam :run!
                                  (find-symbol* :all :rf-comments/tests))
               (error "rf-comments tests failed"))))
