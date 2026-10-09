---
name: pr-review-comments
description: Workflow for addressing a reviewer's comments on a pull request (e.g. Gašper's review of upstream freshehrteam/Open-health-stack#3) — one sub-session, fork issue and fork PR per comment, a step-by-step manual review with joost, cherry-pick to the deployed branch, update the issue, report back to the main session, archive. Use when asked to address, handle, fix or work through review comments on a PR.
---

# /pr-review-comments — one comment → issue → PR → deployed

Proven on upstream PR #3 (8 threads, fork issues #15–#27, PRs #16–#29).
The main session orchestrates; each comment gets its own sub-session.

## Main session

1. **Read the comments.** Upstream (`freshehrteam/Open-health-stack`) can't be
   attached next to the fork (same repo name), so read it from a separate
   session with upstream as its source. That session is read-only for
   `joostholslag-claude`: writes (reviews, comments, issues) return 403.
2. **One sub-session per comment** (`create_session`, source = the fork,
   revision `main`). Comments that edit the same file may share one branch/PR:
   give one session the OWNER role (creates branch, opens the PR, lists both
   `Fixes #`) and the other the PARTNER role (pushes to that branch, adds its
   `Fixes #`, never opens a PR). Seed each prompt with the comment verbatim,
   the proposed fix, and the steps below.
3. **Track** with a one-off `send_later` check-in; report a
   thread → issue → PR → status table. Advise merge order when PRs touch the
   same file.
4. **Archive** the sub-sessions only after all of them are done (ask joost).

## Each sub-session

1. **Issue** on the fork: `PR #<n> review <T#>: <short title>` — the comment
   verbatim, link to the upstream PR, problem, fix, checklist.
2. **Branch + PR** from current `main`, one commit per comment, `Fixes #<issue>`.
   Code comments concise (one line). Run what you can locally (`terraform fmt`,
   `actionlint`, `bash -n`); say plainly what you couldn't run (the terraform
   registry and get.helm.sh are blocked in the container).
3. **Help joost review manually — one step at a time.** For anything he may be
   unfamiliar with (installing tools, `terraform plan`/`apply`, `scw`/`kubectl`,
   GitHub settings), give ONE step, wait for his pasted output, interpret it,
   then give the next. Never a long list of commands at once. His shell is zsh
   on macOS: no `#` comments inside commands, no `<placeholder>` angle brackets.
   Never run applies or touch live infra yourself.
4. **Merge** is joost's. Don't merge or approve.
5. **Cherry-pick to the deployed branch.** The live Scaleway cluster deploys
   from the branch in the `DEPLOY_BRANCH` repo variable (currently
   `claude/nuts-pip-poc`, not `main`). After the merge, `cherry-pick -x` the
   commit(s) there, or the next deploy rolls the fix back or breaks CI (T5's
   6443 lockdown broke CI until it was ported). A push there may start a
   `deploy-scaleway` run that waits for joost's approval; read its log with him.
6. **Update the issue**: tick the checklist, add a short summary comment
   (commits on `main` and on the deployed branch, how it was verified), close it.
7. **Reply upstream**: draft the reply to the reviewer's thread; joost pastes it
   (upstream is read-only for this account).
8. **Report back to the main session** with `send_message` (`@parent`): issue,
   PR, merge commit, port commit, verification, anything left open.
9. **Archive this session** once all of the above is done.

## Known traps

- **No untargeted `terraform apply` from `main`.** `main` lacks the OPA/Nuts work
  that's live from the deployed branch; a plain apply would downgrade the chart
  and destroy the demo-user passwords. Use `-target=` or apply from the
  deployed branch.
- `-var install_apps=false` / `install_cloud_integration=false` are `count`
  toggles: on a live cluster they plan to DESTROY those modules.
- Sessions can't delete remote branches (403); ask joost to delete merged ones.
- The Terraform S3 state has no locking (#31): never run a local apply while a
  `deploy-scaleway` run is in progress.
