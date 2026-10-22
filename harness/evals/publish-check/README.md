# publish-check

Proves: acp publish-check reads every commit on every branch and the files a commit could still add, with bin/sanitize's rules, before a first push: a key only on another branch, deleted from the tree or in a commit message is found, and so are unconfirmed identities, junk, large files, a second pipeline copy, merged and superseded branches and a missing remote; nothing is printed whole, and the repository is byte-identical afterwards.
