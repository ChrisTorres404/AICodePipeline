# worktree-lifecycle

Proves: wo start makes the work order's branch wo/NNNN-slug and its git worktree under the workspace's Worktrees folder, ignored by git and read by no check; wo close removes both once the branch is merged, and keeps them whenever something could be lost; wo start refuses an order whose documents are not committed, and a closed one; wo close refuses while the branch is not merged (ALLOW_UNMERGED=1 overrides); wo verify and wo close refuse inside a worktree.
