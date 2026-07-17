## Git Workflow

Hierarchical topic branching (not git-flow) — no `develop`/`release` branches, no long-lived per-feature branches with cherry-picks. Just a root branch and a nested tree of topic/work branches.

### Branch types

- **`main`** is the root branch (rename `master` on older repos) and reflects what's live in production. No direct commits on `main` — everything arrives via PR.
- **A topic branch**, named `(topic)/main` — `topic` must be a valid DNS subdomain (letters, numbers, hyphens only), e.g. `p1/main`. Often a single author works directly on it. Give it CI: build, test, ephemeral environment creation and deployment. Keep the topic name short — work branches nest under it. A short mnemonic, or a letter plus ticket number, is the usual convention (`i123/main`).
- **A work branch**, named `(topic)/(subtopic)(/subsubtopic)*/work` — nested under a topic branch or another work branch. Work branches aren't deployed, so naming is looser below the topic prefix.
- After a topic branch has merged to `main` and shipped, keep it around and continue branching work branches off it for post-release fixes rather than creating a new topic branch.
- The parent of any branch is whichever `../main` or `../work` sits one level up; CI treats that distinction as the difference between an ephemeral-deployment branch and a plain work branch.
- Never push to a remote branch you didn't create — branch off it and open a PR to its owner instead.
- Avoid multiple people committing directly to one branch.

### Lean process

- Work in small steps and ship to production with minimal delay once complete (review, testing, etc. included).
- Don't start new work before existing work has shipped to production.
- Prefer working directly at the `(topic)/main` level and avoid nested `(topic)/(subtopic)/work` branches when possible — they're for cases that genuinely need isolation, not a default habit.

### Merging: down before up, no rebase

- A PR merges a branch into its immediate parent (a work branch into its topic branch, a topic branch into `main`). A `(subtopic)/work` branch can't jump straight to `main` — it must traverse its parent `(topic)/main` so a full build+deploy is proven before the change reaches production.
- **Merge down (pull the parent's changes into your branch) and resolve conflicts before merging up.** Do this daily for active branches. Aim for PRs that are fast-forward eligible — the branch's commits start right after the parent's last commit, or its final commit is a merge resolving mixed history.
- **No rebase.** It's nicer in isolated cases but too easy to misuse and the leading cause of lost work in this workflow — don't teach or use it here.
- To pick up someone else's already-pushed branch: `git checkout main && git pull && git checkout branch_name` — don't commit directly to it; branch off it instead and PR back to its owner.

```bash
# Create a topic branch
git checkout main && git pull
git checkout -b i123/main
git push -u origin i123/main

# Create a work branch under an existing topic branch
git checkout p1/main && git pull
git checkout -b p1/some_description/work
git push -u origin p1/some_description/work

# Make a change on a branch you own
git checkout some_topic_branch && git pull
# ...edit, then:
git add <file> && git commit -m "why this change" && git push

# Merge down before continuing work (topic branch)
git checkout i123/main && git pull
git merge origin/main
git push

# Merge down before continuing work (work branch) — merge the parent's
# origin ref, not your possibly-stale local copy of it
git checkout p1/foo/work && git pull
git merge origin/p1/main
git push

# Suggest a change to someone else's branch: branch off it, PR back to its owner
git checkout p1/foo/work && git pull
git checkout -b p1/foo/bar/work
# ...edit, then:
git add <file> && git commit -m "why this change"
git push -u origin p1/foo/bar/work
# open a PR targeting p1/foo/work
```

### Opening a PR

- Target the correct parent branch explicitly — DevOps defaults to `main`, which is usually wrong for a nested branch.
- Link the issue/project ticket.
- Describe the change's scope so the reviewer knows what to verify.
- Annotate *why* specific changes were made in the PR description; add code comments too if that clarification would help future maintainers, since PR annotations themselves won't be visible to them.
- Requires approval from someone other than the author (preferably a senior role) before merging into the parent; delete the branch afterward.
- Once a parent branch changes, every sibling branch must merge down the new parent before it can merge up — so minimize parallel work in the same area of a branch tree.

### Mono-repos

Multiple products in one repo mean a PR into a shared parent forces a merge-down across all of them, but conflicts should be rare since changes usually land in different products — treat a conflict there as a signal worth investigating immediately. Revisit this if the merge-down-before-up overhead becomes a real burden in practice.
