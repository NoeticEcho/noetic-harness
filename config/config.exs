import Config

# A run's records are signed with the workspace's `aw` identity when one
# exists. The test suite never signs: a signature would depend on the machine
# the suite ran on.
if config_env() == :test do
  config :noetic_harness, sign_records: false
end
