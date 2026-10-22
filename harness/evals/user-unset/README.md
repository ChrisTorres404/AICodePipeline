# user-unset

Proves: harness/config/test-config.env can be sourced under set -u with USER unset, defaulting DB_USER to the login name, while USER and an exported DB_USER still win.
