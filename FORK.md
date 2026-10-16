# Fork this lab

`dx03v2` is the application half of the Google Cloud pair of this lab; the infrastructure half is
[`tx03v2`](https://github.com/maringelix/tx03v2). Start with the
[FORK.md of tx03v2](https://github.com/maringelix/tx03v2/blob/main/FORK.md): it covers the steps both
repositories share, what a fork does not bring along and your own Google Cloud project. This page adds
what is specific to the app.

What is proven, and how, is in the [status matrix](README.md#status-matrix). In short: the harness,
the kind e2e and the app on the local platform are `verified in CI`; the Google Cloud deploy of v2 is
`not run in the cloud (v2)`. Most documents under `docs/` are in Brazilian Portuguese; this page, the
README, AGENTS.md and CONTRIBUTING.md are in English.

## 1-3. The steps both repositories share

1. Fork both `maringelix/tx03v2` and `maringelix/dx03v2` into your **personal account** and **keep the
   names**: the deploy service account of the tx03v2 bootstrap trusts exactly `<you>/dx03v2`.
2. Enable Actions in both forks: **Actions** tab, **I understand my workflows, go ahead and enable
   them**. Until you do, the required checks never report and no pull request can be merged.
3. Apply the repository settings, which GitHub does not copy to a fork:

   ```bash
   scripts/repo-guardrails.sh <you>/dx03v2   # and the same in tx03v2
   ```

   Here the ruleset requires `static`, `test`, `images`, `e2e` and `e2e-platform`. The script also
   protects the environment `lab` (it fails, instead of skipping, when it cannot: the cloud
   workflows take their credentials through it), and it checks that the OIDC subject of the
   repository is the immutable one, with the owner and repository IDs that the tx03v2 bootstrap
   trusts (it prints the IDs). A repository that predates 2026-07-15 must opt in to immutable
   subject claims first (Settings > Actions > General > OpenID Connect).

## 4. Run the app locally (free)

```bash
make tools                     # the pinned tools into .tools/, each one SHA256-verified
HARNESS_STRICT=1 make verify   # lint, types, unit and integration tests (a throwaway PostgreSQL 17), web tests
make build                     # the two images, the image policy and the trivy gate
make e2e                       # kind: Pod Security restricted, the smoke test, NetworkPolicy probes
make e2e-platform              # the app on the full local platform of tx03v2, the GitOps way
```

You need Node.js 24 (`.nvmrc`) and Docker besides the tools of `make tools`; the devcontainer has both.
`make e2e-platform` clones tx03v2 at the commit of `deploy/local/tx03v2.ref`, builds the whole local
lab, deploys the app through the git server of the lab and Argo CD, runs 18 probes (the smoke test
over HTTPS through an Istio Gateway, mTLS, metrics, alert rules, the dashboard, logs, one trace from the
edge to the database, Trivy reports, the HPA, a zero-downtime rollout, a database backup and restore,
self-heal and two chaos experiments) and always destroys the lab
([docs/LAB_LOCAL.md](docs/LAB_LOCAL.md)). It needs about 8 GB of memory for Docker, or 7 GB with
`LOCAL_SIZE=small make e2e-platform` (the same platform with smaller limits and short retention), and
takes 25-45 minutes on a laptop (about 20 in CI). With less memory, `make e2e` alone still proves the manifests
on kind.

## 5. Test the app against your own tx03v2

By default the platform e2e uses the original `tx03v2` at the pinned commit, locally and in CI. To use
yours:

- locally: `TX03V2_DIR=../tx03v2 make e2e-platform` takes your checkout as it is;
- in the CI of your fork: set the repository variable `TX03V2_REPO`
  (`gh variable set TX03V2_REPO --body https://github.com/<you>/tx03v2.git -R <you>/dx03v2`) and pin a
  commit of your fork in `deploy/local/tx03v2.ref` with a pull request. The pinned commit has to exist
  in that repository: after a **Sync fork** of tx03v2, the commit pinned by the original exists there
  too.

## 6. Make the fork yours

`main` takes pull requests only now. Open one that replaces `@maringelix` with your user in
`.github/CODEOWNERS`; its CI (`static`, `test`, `images`, `e2e`, `e2e-platform`) takes about 25
minutes and you merge it yourself. The README badge, the family table and the security contact keep
pointing to the original repositories: change them if you like, nothing depends on them.

## 7. Deploy to your own Google Cloud project (costs money)

First complete the Google Cloud setup and the `tx03v2` full platform steps in its `FORK.md`. Set the
three repository variables in `docs/RUNBOOK.md` section 6 and protect the `lab` environment.

The release uses two manual workflows, both dispatched from `main`:

1. Run `publish-images` with `ci_run_id` set to a successful CI run for the current `main` commit. It
   verifies the five required checks, publishes the already-tested image IDs to GHCR without rebuild,
   and creates SBOMs and Sigstore attestations.
2. Run `deploy-gcp` with `release_run_id` set to that publisher run. The workflow re-verifies the CI,
   image digests, SBOM hashes and attestations before the `lab` environment approval. After approval,
   it uses Workload Identity Federation and promotes those exact digests to Artifact Registry, then
   deploys by Argo CD GitOps.

The normal workflow requires the `tx03v2` `full` profile and the `dx03v2` Argo CD Application. It does
not rebuild or publish a different image. A direct `DEPLOY_MODE=push` run is available for a deliberate
manual exercise without Argo CD; see `docs/RUNBOOK.md` and use the same verified release bundle.

## 8-9. Report the run and keep the fork up to date

Open a **Cloud run report** in your fork or, better, in the
[original repository](https://github.com/maringelix/dx03v2/issues/new/choose). Use **Sync fork** to
take the changes of the original, and run `scripts/repo-guardrails.sh` again when
`.github/rulesets/main.json` changed.

## Troubleshooting

| Symptom | Fix |
|---|---|
| A pull request waits forever for a required check | Actions are still disabled in the fork: step 2 |
| `repo-guardrails.sh` fails with "the workflows of this fork are not enabled yet" | step 2, then run it again |
| `make test` cannot reach PostgreSQL | the harness starts a throwaway `postgres:17-alpine` with Docker; inside a container that uses the Docker of the host, set `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER` and `DB_PASSWORD` instead (`DB_NAME` must end in `_test`: the tests drop and recreate tables) |
| `make e2e-platform` gets killed or Docker freezes | give Docker about 8 GB of memory (Docker Desktop on WSL 2: `memory=8GB` under `[wsl2]` in `%UserProfile%\.wslconfig`, then `wsl --shutdown`) and run one lab at a time; with 7 GB, `LOCAL_SIZE=small make e2e-platform`; with less memory, `make e2e` alone still proves the manifests on kind |
| `TX03V2_REPO must be an https git URL` | set the variable to the https clone URL of your tx03v2 fork |
| `commit ... of deploy/local/tx03v2.ref is not in ...` | sync your tx03v2 fork, or pin a commit of it |

## Contributing back

Pull requests to the original repository are welcome: see [CONTRIBUTING.md](CONTRIBUTING.md). A
change to `api/`, `web/` or `e2e/` has to reach the three app repositories (the parity rule of
AGENTS.md). Workflow runs from forks wait for the maintainer's approval, and the same harness decides.
