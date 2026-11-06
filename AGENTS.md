# Agent instructions

Guidance for AI coding agents (and humans) working on rf-comments. The
README has the full developer guide; the design rationale is in DESIGN.md.

## Branching workflow

`master` is the default branch and is always deployable.

1. **Start every feature or fix on a new, descriptively named branch cut from
   the latest `master`**, for example `feature/reply-threads`,
   `fix/ses-retry-on-throttle` or `docs/backup-guide`:

   ```bash
   git fetch origin master && git checkout -b feature/<short-name> origin/master
   ```

2. **Work on that branch until the feature is complete and tested.** Commit
   as often as useful and push the branch. `make test` must pass. For changes
   touching the Docker build, `make docker-test` must pass too. Pushing the
   branch triggers the GitHub Actions `Tests` workflow
   (`.github/workflows/test.yml`), and that run must be green before you
   merge.
3. **Merge into `master` when done**, using a merge commit so the feature
   shows up as one unit in the history, and push:

   ```bash
   git checkout master && git pull origin master
   git merge --no-ff feature/<short-name>
   make test && git push origin master
   ```

4. **Leave the branch in place.** Don't delete merged feature branches; their
   names record what was done. Start the next piece of work on a fresh branch
   instead of reusing an old one.

Never commit untested work directly to `master`.

## Project conventions

- Common Lisp (SBCL); the code is an ASDF system (`rf-comments.asd`) with
  sources in `src/` and FiveAM tests in `tests/`.
- Add tests alongside every behaviour change: unit tests in
  `tests/unit.lisp`, end-to-end HTTP tests in `tests/integration.lisp`.
- Schema changes go in a *new* entry at the end of `*migrations*` in
  `src/db.lisp`. Never edit an applied migration.
- Generate HTML only through Spinneret, so output stays escaped.

## Writing routes

Declare routes with the macros in `src/routes.lisp`:

- `defpage` for HTML GET routes. It adds the default security headers.
- `defaction` for every POST. It always runs the same-origin (CSRF) check
  first and disables caching. **Never use a raw `easy-routes:defroute` for a
  POST.** The test suite fails if any POST route skips `@same-origin`.
- `with-valid-inputs` to clean and validate form fields instead of nesting
  `multiple-value-bind` checks.
- Plain `easy-routes:defroute` only for non-HTML GETs (scripts, JSON, health).
- Secrets come from the environment (`.env`, never committed).
