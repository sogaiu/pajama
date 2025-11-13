(declare-project
  :name "pjm"
  :description "pajama is a Janet Project Manager tool."
  :url "https://github.com/sogaiu/pajama")

(declare-source
  :prefix "pjm"
  :source ["pjm/cc.janet"
           "pjm/cli.janet"
           "pjm/commands.janet"
           "pjm/config.janet"
           "pjm/dagbuild.janet"
           "pjm/declare.janet"
           "pjm/init.janet"
           "pjm/make-config.janet"
           "pjm/pm.janet"
           "pjm/rules.janet"
           "pjm/shutil.janet"
           "pjm/scaffold.janet"
           "pjm/cgen.janet"])

(declare-binscript
  :main "pjm/pjm"
  :hardcode-syspath true
  :is-janet true)

# Install the default configuration for bootstrapping
(def confpath (string (dyn :modpath) "/pjm/default-config.janet"))

(if-let [bc (os/getenv "PJM_BOOTSTRAP_CONFIG")]
  (install-file-rule bc confpath)

  # Otherwise, keep the current config or generate a new one
  (do
    (if (os/stat confpath :mode)

      # Keep old config
      (do
        (def old (slurp confpath))
        (task "install" []
              (print "keeping old config at " confpath)
              (spit confpath old)))

      # Generate new config
      (do
        (task "install" []
            (print "no existing config found, generating a default...")
            (spit confpath (generate-config))
            (print "created config file at " confpath))))))
