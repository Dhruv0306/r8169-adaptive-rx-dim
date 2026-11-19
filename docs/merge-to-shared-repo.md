# Merging the private repository back into the shared repository

Status: this is the procedure that was used for the merge of the tag `v1.0`, kept as a record. The statements listed in section 6.3 were updated in the same pull request as the merge.

Phases 0 to 3 were pushed to the shared repository (`origin`, `Dhruv0306/r8169-adaptive-rx-dim`, public). Phases 4 and 5 and everything after were done in the private repository (`private`, `Dhruv0306/r8169-adaptive-rx-dim-private`, no collaborators) so that later work stayed private. This document says how to bring all of it back into the shared repository, step by step, with a check after each step and the conditions under which to stop.

**Merging publishes everything.** The shared repository is public, so every commit, file and tag that reaches it is visible to everyone. Read section 2 before the first push.

## 1. The rules from the private-repository setup

These rules were set when the work moved to the private repository and still apply:

- Push to `origin` only by naming the branch or tag explicitly. Never `git push origin --all`, `--mirror` or `--tags`, and never `--all` with a changed default.
- Run `git push --dry-run -v <remote> <ref>` first and read the target line before any push you are unsure about.
- Do not fork the private repository and do not add anyone to it.
- Plans and notes kept outside the repositories (`switch_to_private.md` and similar) must not be committed.
- Fetching from `origin` publishes nothing; only pushes do.

## 2. Before anything is pushed

### 2.1 Decide what is allowed to become public

Run these in the PC clone, on the branch you intend to publish (`private/main`):

```bash
cd /home/aoscsg623/Downloads/r8169-adaptive-rx-dim
git fetch private && git fetch origin
git switch -c check-publish private/main            # a scratch branch
git grep -nEI '([0-9]{1,3}\.){3}[0-9]{1,3}' -- . ':!patches' ':!*.csv' ':!*.json' | grep -vE '127\.0\.0\.1|0\.0\.0\.0' | head -40
git grep -nEI 'BEGIN [A-Z ]*PRIVATE KEY|ghp_[A-Za-z0-9]{20,}|password|secret|token' | head
git grep -nI 'aoscsg623' | head -20
git grep -nIi 'switch_to_private\|private repo' | head -20
git log --format='%an <%ae>%n%cn <%ce>' private/main | sort -u
```

| Finding | Decision |
|---|---|
| Private IP addresses of the author's LAN (for example the peer's address in `results/*/meta*` files or `peer.txt`) | Private addresses (10.x.x.x, 192.168.x.x) are not reachable from outside and are usually acceptable. Decide whether you want them public; if not, replace them in a new commit before merging (see 2.2) |
| The user name `aoscsg623` and paths such as `/home/aoscsg623/Downloads/...` in docs and logs | Harmless, but the paths are in the setup documents on purpose |
| Any key, token or password | Must never be published. The module signing key is only referenced by path (`certs/signing_key.pem` in the kernel tree) and is not in the repository; if the scan finds any real secret, stop and remove it from history before anything is pushed |
| References to the private repository or to private notes in the documents | Update them after the merge (section 6) |
| Author and committer addresses | Must be `Dhruv Rakeshbhai Patel <dpatel5469@gmail.com>`; the only other identity should be the `Co-authored-by` trailer text |

Also look at the size of what you are publishing: `git count-objects -vH` and `du -sh results docs`. The raw logs are text and small; the diagrams add about 3 MB of PNG.

### 2.2 Replace values you do not want public (optional)

If you decide to hide the LAN address or a hostname, do it as a normal commit on the branch before merging (for example a script-driven replace of `10.8.1.53` by `<peer>` in the `results/` meta files). Note that the old values remain in the history of the private repository and in every commit before this one; a commit that only replaces them does not remove them from history. If they must not be public at all, use a history rewrite (for example `git filter-repo`) on a copy, and agree it with the teammate first because it changes commit hashes. For a private LAN address this is normally not worth it.

### 2.3 Make a backup you can return to

```bash
git bundle create ~/r8169-private-backup-$(date +%F).bundle --all     # a local file, publishes nothing
git bundle verify ~/r8169-private-backup-*.bundle
git branch -D check-publish
```

## 3. Find out how the two repositories relate

```bash
git remote -v                                          # origin = shared (https://github.com/Dhruv0306/r8169-adaptive-rx-dim), private = ...-private
git merge-base --is-ancestor origin/main private/main && echo "shared main is inside private main"
git log --oneline private/main..origin/main            # commits only in the shared repository
git log --oneline origin/main..private/main | wc -l    # commits only in the private repository
git tag -l --contains private/main | head              # tags on private/main (phase4-done, v1.0)
```

| Result | Case | What it means |
|---|---|---|
| "shared main is inside private main" and the first log is empty | **A. Clean** | The private repository only added commits on top of the shared main. The merge is a straight addition |
| The first log lists commits (for example a teammate's work) | **B. Diverged** | The shared repository moved on. Merge `origin/main` into your branch first (section 4, case B) |
| `git merge-base origin/main private/main` prints nothing | **C. Unrelated** | The histories do not share a commit. Stop and ask for advice; do not use `--allow-unrelated-histories` blindly |

From the earlier pushes (the private repository accepted a push from `4271139`, the Phase 3 merge on the shared main), case A or B is expected.

## 4. Merge by pull request (recommended)

A pull request into the shared `main` keeps the review trail and follows the earlier practice (merge commit, branch kept).

### Case A: clean

```bash
git switch -c Dhruv_Patel/r8169-phases-4-5 private/main
git log --oneline -5                                    # the Phase 5 merge on top, then the docs commits
git push --dry-run -v origin Dhruv_Patel/r8169-phases-4-5     # read the target line: it must name origin and this branch
git push -u origin Dhruv_Patel/r8169-phases-4-5
```

Then on GitHub, in the **shared** repository, open a pull request from `Dhruv_Patel/r8169-phases-4-5` into `main`. Check the "Files changed" tab (see section 5), then merge with a merge commit and keep the branch.

### Case B: the shared repository has new commits

```bash
git switch -c Dhruv_Patel/merge-private-into-shared private/main
git merge origin/main                                   # resolve conflicts if any
```

Likely conflicts are in `README.md`, `docs/phases.md` and `docs/handoff.md`, which both sides may have edited. Resolve them by keeping the private version of the project state and adding the other side's additions; never drop a line without reading it. After the merge, repeat the checks of section 5 on this branch, then push it by name:

```bash
git push --dry-run -v origin Dhruv_Patel/merge-private-into-shared
git push -u origin Dhruv_Patel/merge-private-into-shared
```

and open the pull request as in case A.

### Quick alternative when nothing is protected and the case is A

If `main` of the shared repository has no branch protection and you do not need a pull request, a fast-forward push gives identical commit hashes:

```bash
git push --dry-run -v origin private/main:main          # must be a fast-forward; read the output
git push origin private/main:main
```

Use a pull request when in doubt.

## 5. Check before merging the pull request

```bash
git switch Dhruv_Patel/r8169-phases-4-5                 # or the merge branch
git status --short                                      # must be empty
git diff --stat origin/main...HEAD | tail -5            # what will appear in the shared repository
bash scripts/check_series.sh -t ~/linux-r8169-clean -c  # the series still applies on a clean v7.2.15
ls patches docs docs/diagrams docs/results | head -60
```

On GitHub, in the pull request, check that:

- the changed files are the ones you expect (no stray files, no editor backups);
- the Mermaid diagrams in `docs/diagrams/*.md` render (open one);
- the PNG figures in `docs/figures/` and `docs/diagrams/img/` display;
- the Phase 5 results file and the report open without broken links.

## 6. After the merge

### 6.1 Tags

The tags `phase4-done` and `v1.0` exist only on the private repository. After the merge, push the ones you want public, by name:

```bash
git push --dry-run origin v1.0
git push origin v1.0
git push origin phase4-done       # optional
```

The `v1.0` tag points at the last commit of the private `main`, which is an ancestor of the merge commit, so it is valid in the shared repository. `phase3-done` is already on both remotes.

### 6.2 Verify from a fresh clone

```bash
cd /tmp && rm -rf verify && git clone https://github.com/Dhruv0306/r8169-adaptive-rx-dim verify && cd verify
git log --oneline -5
git tag | tail
ls patches docs/results
bash scripts/check_series.sh -t ~/linux-r8169-clean -c
```

### 6.3 Update the statements that are no longer true

Several documents say that Phases 4 and 5 live in the private repository. Find them and edit them in a normal pull request:

```bash
git grep -nIi 'private' -- README.md docs ':!docs/merge-to-shared-repo.md' ':!docs/results'
```

Typical places: the Repository row of `docs/handoff.md` (section 2), the header of `docs/report.md` ("phases 0 to 3, public, and its private continuation"), section 6 of `docs/results/phase_5_report_and_demo.md` ("The shared repository stays at the end of Phase 3 and does not receive Phase 4 or 5 work"), and the last paragraph of [diagram 9](diagrams/09-phases.md). Replace them with a sentence saying that all phases are in the shared repository, with the date of the merge.

### 6.4 The private repository

Keep it until the merged shared repository has been verified from a fresh clone (6.2). After that it can stay as an archive or be archived on GitHub (Settings, Archive this repository). Do not delete it before the verification and the backup bundle of 2.3 exist.

### 6.5 Local remotes

Once everything is in the shared repository, set the default back so that a plain `git push` goes to `origin`, if you want that:

```bash
git config remote.pushDefault origin
git config --get remote.pushDefault
```

## 7. A suggested pull request description

Title: `Phases 4 and 5: measurement, report, demo and documentation`

Body: the contents of Phase 4 (no driver change, calibration, final matrix of 12 runs per cell, level traces, stepped load, figures) and Phase 5 (report, demo script and run sheet, series check, final-check run, rehearsals and fallback recording), the documentation set listed in [`README.md`](README.md), and the statement that the patch series in `patches/` is unchanged since Phase 3 (six patches against `v7.2.15`).

## 8. If something goes wrong

| Problem | What to do |
|---|---|
| A push went to the wrong remote or branch | Do not force-push to fix it. Delete only the new branch on that remote (`git push <remote> --delete <branch>`) if nothing else uses it, and tell the teammate if the shared repository was affected |
| A secret was pushed | Treat it as compromised: revoke or rotate it first, then remove it from history with `git filter-repo` on a copy and coordinate a rewrite; deleting the file in a new commit is not enough |
| Merge conflicts you cannot resolve | `git merge --abort`, return to `private/main`, and merge in smaller steps (`git merge origin/main~N`) or ask the teammate which side to keep |
| The pull request shows unexpected files | Close it without merging, find the cause with `git diff --stat origin/main...HEAD`, fix on the branch, push again |
| You need to go back to the state before the merge | The bundle of 2.3 contains every branch and tag of the private repository: `git clone ~/r8169-private-backup-*.bundle restore` |
