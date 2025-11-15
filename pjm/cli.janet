###
### Command Line interface for pjm.
###

(import ./config :as cnf)
(import ./commands)
(import ./default-config)

(def- argpeg
  (peg/compile
    '(choice (sequence "--"
                       (capture (some (if-not "=" 1)))
                       (choice (sequence "="
                                         (capture (any 1)))
                               -1))
             (sequence (capture "-")
                       (some (capture (range "AZ" "az")))))))

(comment

  (peg/match argpeg "--local")
  # =>
  @["local"]

  (peg/match argpeg "--local=fun")
  # =>
  @["local" "fun"]

  (peg/match argpeg "--")
  # =>
  nil

  (peg/match argpeg "-l")
  # =>
  @["-" "l"]

  (peg/match argpeg "-")
  # =>
  nil

  )

(defn setup
  ``
  Load configuration from the command line, environment variables,
  and configuration files. Returns array of non-configuration
  arguments as well. Config settings are prioritized as follows:

  1. Commmand line settings
  2. The value of `(dyn :pjm-config)`
  3. Environment variables
  4. Config file settings (default-config if non specified)
  ``
  [args]
  (cnf/read-env-variables)
  (cnf/load-options)
  (def cmdbuf @[])
  (var flags-done false)
  (each a args
    (cond
      (= a "--")
      (set flags-done true)

      flags-done
      (array/push cmdbuf a)

      (if-let [m (peg/match argpeg a)]
        (do
          (def key (keyword (get m 0)))
          (if (= key :-) # short args
            (for i 1 (length m)
              (setdyn (get cnf/shorthand-mapping (get m i)) true))
            (do
              # long args
              (def value-parser (get cnf/config-parsers key))
              (unless value-parser
                (error (string "unknown cli option " key)))
              (if (= 2 (length m))
                (do
                  (def v (value-parser key (get m 1)))
                  (setdyn key v))
                (setdyn key true)))))
        (do
          (when (index-of a ["janet" "exec"]) (set flags-done true))
          (array/push cmdbuf a)))))

  # Load the configuration file, or use default config.
  (if-let [cd (dyn :pjm-config)]
    (cnf/load-config cd true)
    (if-let [cf (dyn :config-file (os/getenv "JANET_PJM_CONFIG"))]
      (cnf/load-config-file cf false)
      (cnf/load-config default-config/config false)))

  # Local development - if --local flag is used, do a local installation to a tree.
  # Same for --tree=
  (cond
    (dyn :local) (commands/enable-local-mode)
    (dyn :tree) (commands/set-tree (dyn :tree)))

  # Make sure loaded project files and rules execute correctly.
  (unless (dyn :janet)
    (setdyn :janet (dyn :executable)))
  (put root-env :syspath (dyn :modpath))

  # Update packages if -u flag given
  (when (dyn :update-pkgs)
    (commands/update-pkgs))

  cmdbuf)

(defn run
  "Run CLI commands."
  [& args]
  (def cmdbuf (setup args))
  (if (empty? cmdbuf)
    (commands/help)
    (if-let [com (get commands/subcommands (first cmdbuf))]
      (com ;(slice cmdbuf 1))
      (do
        (print "invalid command " (first cmdbuf))
        (commands/help)))))

(defmacro pjm
  "A Macro User Interface for pjm to be used from a repl in a way similar to the command line."
  [& argv]
  ~(,run ,;(map |(if (bytes? $)
                   (string $)
                   $)
                argv)))

(defn main
  "Script entry."
  [& argv]
  (run ;(tuple/slice argv 1)))
