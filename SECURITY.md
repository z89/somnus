# security

somnus changes a persistent macOS power setting through a root helper, so a power-state failure or a bug in the privilege boundary is a security issue.

## reporting

report vulnerabilities privately with [GitHub's security advisory form](https://github.com/z89/somnus/security/advisories/new), not in a public issue. never include credentials, signing certificates or unredacted machine logs.

a useful report has exact reproduction steps, the affected commit, and redacted output from `somnus doctor` or the unified log.

## what counts

- a way past the helper's caller checks, or a way to make it run something other than its fixed `pmset` commands.
- a failed write reported as done.
- `SleepDisabled` left on after the safety net, the lease or an explicit off should have cleared it.

## supported versions

only the latest `main` is supported until somnus publishes versioned releases.
