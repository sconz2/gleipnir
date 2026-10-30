# Gleipnir's tests

Three layers, from quickest to most thorough.

## Unit tests (any computer with Python 3.8+ and git)

```bash
python3 -m unittest discover tests/unit
```

- `test_heimdall.py`: Heimdall's checks. A changed or newly runnable git hook, a `package.json` deep in the project, a risky git setting, a link that's re-pointed, a huge file, a folder it can't read, terminal escapes in file names, and a branch whose commits change `package.json` while the working files are put back.
- `test_apps.py`: the machine config's `apps`. Bad names, folders outside the project, Gleipnir's own ports, and two apps on the same port or folder.
- `test_config.py`: the whole-config check that provisioning runs first. Typos in setting names, wrong types and ranges, comments (`_` keys), database names, versions written as text or numbers, extension IDs, site names, older configs, and the example configs passing.

## Lint (Linux; ShellCheck and Ruby are used if installed)

```bash
tests/lint.sh
```

`bash -n` and ShellCheck on the shell scripts, a syntax check on the Python scripts and the Vagrantfile. GitHub runs this and the unit tests on every push (`.github/workflows/checks.yml`).

## The self-test (inside a machine)

```bash
tests/vm/selftest.sh my-project            # or, after vagrant ssh: sudo gleipnir-selftest
tests/vm/selftest.sh my-project --quick    # without Gjöll's network tests
```

It checks that each user can do what it should and nothing more:

- **Users:** none has `sudo`; `claude` and `runner` can't use cron, linger or polkit, and Gjöll starts before logins at boot.
- **Your copy:** Claude and the dev servers can't see it. Git has no exceptions that would let `dev` work in Claude's copy.
- **Claude's copy:** its `.git` is Claude's alone, and `dev`'s git refuses to run there. A hook and an `fsmonitor` setting planted in a repo of Claude's never run as `dev`.
- **Settings:** Claude's managed settings, `CLAUDE.md` and `.npmrc` are root's.
- **Gjöll:** every firewall rule is in place for IPv4 and IPv6. The network tests (no DNS, no direct connections, the proxy's refusals) run unless `--quick`.
- **Dev servers:** they run as `runner` and can't see your copy. `dev` can control them and nothing else.
- **The editor:** it asks for a password, which only root can read.
- **The database:** the app's user isn't a superuser, and can make databases only if `postgres.createdb` says so.
- **Heimdall:** it reports a changed hook and a deeply nested `package.json`.

Every provision runs it last (`--quick`, since the Claude step has just run the network tests). If anything fails, so does the provision. Use a machine with nothing real in it to try changes to Gleipnir itself.