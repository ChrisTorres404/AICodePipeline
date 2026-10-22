# playbooks-dir

Proves: PLAYBOOKS_DIR names the project's playbooks folder relative to the project (or absolute, outside it): install makes it, wo and bug promote write into it from any folder, playbook finds it from its own install's config read as data, doctor checks it, a value that is not a plain folder, lies outside the pipeline's and the workspace's top folders, or reaches the code folder by any spelling or link is refused, and unset the playbooks stay inside the install as before.
