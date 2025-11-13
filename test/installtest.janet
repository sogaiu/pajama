###
### Test that the installation works correctly.
###

(os/cd "testinstall")
(defer (os/cd "..")
  (os/execute [(dyn :executable) "runtest.janet"] :px))
