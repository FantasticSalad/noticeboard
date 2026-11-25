# Repository work

Work on a branch, never directly on the default branch. Run `bash tests/run-all.sh` before every
commit, and `claude plugin validate --strict .` when the manifests or the skill change.

Everything outside `docs/internal` must be fit to publish at every commit: no personal names,
paths, machines or private repository names. `tests/public-scan.sh` checks it on every run.
Public files never link into `docs/internal`.

Use synthetic fixtures only. Don't change user settings, rewrite published history, or publish a
release; publication is separately gated, and `docs/internal` holds the release record.

Keep the scripts working on bash 3.2: no negative array indexes, no `${var,,}` or `${var^^}`, no
`mapfile`, no associative arrays, and arrays declared with `local -a name; name=(...)`.

Cloud sessions work only on their assigned branch and end with a commit note: Branch, State,
Checks, Next.
