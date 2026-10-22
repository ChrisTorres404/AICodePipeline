# eval-isolation

Proves: bin/eval run gives each evaluation its own HOME, XDG_CONFIG_HOME, git configuration (a test identity, no system file) and TMPDIR inside its scratch folder, so none reads or writes the person's own, and clears the person's git identity, injected settings, repository location and XDG data, state and cache folders.
