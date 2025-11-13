#!/usr/bin/env janet

# A script to install pjm to a given tree. This script can be run during installation
# time and will try to autodetect the host platform and generate the correct config file
# for installation and then install pjm

# XXX: following line seems unneeded
(import ./pjm/shutil)
(import ./pjm/make-config)

(def destdir (os/getenv "DESTDIR"))
(defn do-bootstrap
  [conf]
  (print "Running pjm to self install...")
  (os/execute [(dyn :executable) "pjm/cli.janet" "install" ;(if destdir [(string "--dest-dir=" destdir)] [])]
              :epx
              (merge-into (os/environ)
                          {"PJM_BOOTSTRAP_CONFIG" conf
                           "JANET_PJM_CONFIG" conf})))

(when-let [override-config (get (dyn :args) 1)]
  (do-bootstrap override-config)
  (os/exit 0))

(def temp-config-path "./temp-config.janet")
(spit temp-config-path (make-config/generate-config (or destdir "")))
(do-bootstrap temp-config-path)
(os/rm temp-config-path)
