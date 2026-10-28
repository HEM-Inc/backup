# Versioning

This project follows [Semantic Versioning](https://semver.org/) — see the
[`VERSION`](VERSION) file for the current version.

**On every commit you make in this repo**, before running `git commit`,
update `VERSION` and stage it as part of that same commit:

1. Read the current value of `VERSION`.
2. Look at the Conventional Commit type of the commit you're about to make:
   - a breaking change (`!` on the type, or a `BREAKING CHANGE:` footer,
     regardless of type) → bump major (`(X+1).0.0`, reset minor and patch
     to 0)
   - `feat:` (non-breaking) → bump minor (`X.(Y+1).0`, reset patch to 0)
   - anything else conventional (`fix:`, `docs:`, `chore:`, `refactor:`,
     `test:`, `build:`, `ci:`, `perf:`, `style:`, `revert:`) → bump patch
     (`X.Y.(Z+1)`)
3. Write the new value to `VERSION` and `git add VERSION` alongside the
   rest of the commit's changes — the bump belongs in the same commit, not
   a separate one.

When the user asks for a release, tag `HEAD` as `v$(cat VERSION)` —
`VERSION` already reflects the correct next version from the commits since
the last tag, so there's no number to ask the user for or guess at. Pushing
that tag is what triggers `.github/workflows/publish.yml`, which builds and
pushes `ghcr.io/hem-inc/backup` for `linux/amd64,linux/arm64`.

# Bumping pinned versions

The base images (`FROM ... @sha256`), supercronic and gosu are pinned with
digests or checksums. Before bumping any of them, check for active breaches and
issues first: upstream archived or abandoned, security advisories whose range
covers the target version, open issues and release notes for that release, and
recent supply-chain or breach news about the project or its publisher. Report
what you found before changing anything, and stop if there is an active
problem. The full checklist is in `../docker/CLAUDE.md`.

Read-only GitHub API calls must pass `--method GET`: any `-f` or `-F` flag
otherwise turns `gh api` into a POST.
