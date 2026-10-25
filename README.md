# Gleipnir

A Vagrant VM for running Claude Code safely: the project lives inside the VM, Claude runs as a restricted, firewalled user, and you review and commit from a browser-based editor.

> Gleipnir is an independent project and isn't affiliated with or endorsed by Anthropic. Using Claude Code is subject to Anthropic's terms.

In Norse myth, Gleipnir was the binding that held the giant wolf Fenrir: as thin as a silk ribbon, but impossible to break. Its parts are named from the same story: **Gjöll** is the firewall, **Heimdall** the change checks and **Týr** the managed settings.

## Status

Work in progress. Built so far:

- [x] The VMs, users, Node.js and cloning your project
- [x] The browser editor (code-server)
- [x] Claude Code with its firewall, managed settings and change checks
- [x] Optional PostgreSQL, and copying in your `.env`
- [ ] The dev server
- [ ] Optional Playwright
- [ ] Running on a VPS

## How it works

- **One Gleipnir folder, one VM per project.** Each file in `machines/` defines a VM, named after the file. Update Gleipnir once and every VM picks it up on its next provision.
- **Each project is separate.** Every VM has its own users, firewall and Claude login, so Claude working on one project can't see another.
- **Your project lives on the VM's own disk**, cloned from its git repo, not shared from your computer. That keeps it fast and keeps project code off your machine.
- **Two working users per VM, neither with `sudo`:** `dev` for your daily work (the editor, git, the dev server) and `claude` for Claude Code, which you start from your own terminal through `vagrant ssh`. They share the project through a `project` group.
- **Your computer only runs a browser.** Each VM's editor and app are reached on your own `localhost`, through forwarded ports.
- **One entry point:** `install.sh` does all the setup inside a VM. Vagrant runs it for you; on a VPS you run it yourself.

## Requirements

- [Vagrant](https://developer.hashicorp.com/vagrant) 2.4 or later
- [VirtualBox](https://www.virtualbox.org/)
- A Claude Pro, Max, Team or Enterprise plan, or an Anthropic API key
- About 4 GB of free memory for each VM you run at the same time

## Adding a project

Everything for a machine is named after it. For a machine called `my-project`:

| File | What it is |
| --- | --- |
| `machines/my-project.json` | Its config. The file name is the VM's name: lowercase letters, digits and dashes |
| `keys/my-project` | The repo's deploy key (the private half; `keys/my-project.pub` is the half you give GitHub). Needed for `git@…` repo URLs |
| `env/my-project.env` | The project's `.env` file. Optional: used if it's there |

All three folders are ignored by git, so none of them end up in Gleipnir's own repo. To use a file with a different name, give its path in the config with `deploy_key` or `env_file` (see [Configuration](#configuration)).

1. **Create a deploy key** for the project's repo, without a passphrase, in Gleipnir's `keys/` folder:

   ```bash
   ssh-keygen -t ed25519 -f keys/my-project -C "my-project VM" -N ""
   cat keys/my-project.pub
   ```

   On GitHub, open the project repo's **Settings → Deploy keys**, add the public key, and tick **Allow write access**. The key only works on that one repo.

2. **Create the machine's config:**

   ```bash
   cp machines/example.json.example machines/my-project.json
   ```

   Set `repo` (the `git@github.com:…` form) and your git name and email. If another machine already uses ports 8080, 5173 or 54320, pick different `ports`. For a database, set `postgres.enabled` to `true` and choose a password (see [The database](#the-database)).

   If the project needs a `.env` file, save it as `env/my-project.env`.

3. **Start it:**

   ```bash
   vagrant up my-project
   ```

### Checking it worked

After `vagrant ssh my-project`:

```bash
id dev; id claude                       # both in group "project", neither in sudo
node -v                                 # the version from the config
ls -la /srv/project                     # owned by dev, group project
sudo -u dev git -C /srv/project status  # a clean working tree
```

## Using the editor

Open `http://localhost:8080` in Chrome or Firefox (or the `ports.editor` you chose) and log in.

The password is printed once, when the machine is first set up. To look it up again:

```bash
vagrant ssh my-project -c "sudo grep password: /home/dev/.config/code-server/config.yaml"
```

The editor runs as the `dev` user and opens your project in `/srv/project`. Its built-in terminal is a shell as `dev`, for git, npm and tests. Use the Source Control view to review changes and commit.

Claude Code isn't run from the editor; see [Using Claude Code](#using-claude-code).

Safari on older macOS versions can struggle with the editor; a current Chrome or Firefox works best.

## The database

With `postgres.enabled` set to `true`, the machine runs PostgreSQL (version 18 by default) with a user and the databases listed in `postgres.databases`. Provisioning again adds any new databases; it never drops or changes existing ones.

Inside the machine, the app, tests and Claude connect to `127.0.0.1:5432`. Point your `.env` there:

```
DATABASE_URL=postgres://app:change-me@127.0.0.1:5432/my_project
```

From your computer, use any database tool (TablePlus, DBeaver, DataGrip, `psql`) with:

| Setting | Value |
| --- | --- |
| Host | `localhost` |
| Port | `54320` (or the `ports.db` you chose) |
| User / password | `postgres.user` / `postgres.password` |
| Database | one of `postgres.databases` |

The port only listens on your computer's own `localhost`, so nothing else on your network can reach it.

The database user isn't a PostgreSQL superuser, on purpose: a superuser can run shell commands on the server, which would let anything holding the password step around the machine's restrictions. For admin work, run `sudo -u postgres psql` after `vagrant ssh`.

### The `.env` file

`env/my-project.env` is copied to `/srv/project/.env` on every provision, readable only by `dev` and `claude`. **The copy on your computer wins:** changes made inside the machine are overwritten.

After editing it, copy just that file across, which takes a few seconds instead of a full provision:

```bash
vagrant provision --provision-with env-upload,env my-project
```

To save typing, add an alias to your shell profile (`~/.zshrc` on a Mac) that works for any machine:

```bash
alias genv='vagrant provision --provision-with env-upload,env'
```

Then, from the Gleipnir folder, run `genv my-project`.

## Using Claude Code

Start Claude from a terminal on your computer:

```bash
vagrant ssh my-project
claude
```

Or in one step: `vagrant ssh my-project -- -t claude`. The first time, Claude Code shows a login link: open it in your browser, sign in, and paste the code back.

The `claude` command:

1. Checks that **Gjöll**, the firewall, is up, and refuses to start if it isn't.
2. Switches the project to a `wip/<date>` branch, so Claude's work stays off `main`.
3. Takes a snapshot for **Heimdall**, then starts Claude Code as the restricted `claude` user, in `/srv/project`.
4. When you exit Claude, prints Heimdall's summary of anything changed that can run code.

### Reviewing and merging Claude's work

Claude commits as it goes on its `wip/` branch, and anything left over is saved as a "Checkpoint" commit at the end of each turn. Claude can't commit to `main`, and never pushes. In the editor's terminal:

```bash
git diff main...wip/2026-10-25        # everything on the branch
git switch main
git merge --squash wip/2026-10-25     # all of it as one change
git commit                            # write the final message
git push
git branch -D wip/2026-10-25
```

### What holds Claude in place

- **The `claude` user** has no `sudo` and can't read `dev`'s home, so your git key and editor password are out of its reach.
- **Týr**, the managed settings in `/etc/claude-code/`, are owned by root and override any user or project settings. They block Claude's file tools from `.env` files, turn off non-essential traffic, and run Heimdall's checks. Claude also gets a root-owned `CLAUDE.md` describing the machine and its git rules.
- **Gjöll** limits the `claude` user to Anthropic, the npm registry and the sites you list in `claude.allowed_domains`. Nothing else in the machine is restricted. It refreshes the sites' addresses every 30 minutes.
- **Heimdall** flags changes to package scripts, tool configs and shell scripts, npm package changes (watch for look-alike names), and new git hooks or settings that run commands: after each turn, and in a summary when you exit.
- **npm install scripts** are off for the `claude` user.

To let Claude reach another site, add it to `claude.allowed_domains` and run `vagrant provision my-project`. Setting `claude.network` to `"open"` removes the allowlist entirely; Claude's connections are then logged (`sudo journalctl -k | grep gjoll`). Use it only on machines with nothing sensitive in them.

## Everyday commands

```bash
vagrant status                # every machine and whether it's running
vagrant up my-project         # start one (a bare `vagrant up` starts none)
vagrant ssh my-project
vagrant halt my-project
vagrant provision my-project  # apply config changes or a Gleipnir update
genv my-project               # copy just the .env across (see The .env file)
vagrant reload my-project     # restart it; needed after changing ports
```

To update Gleipnir itself: `git pull` in this folder, then `vagrant provision <name>` for each running machine.

## Configuration

Each `machines/<name>.json` file supports:

| Field | Default | What it sets |
| --- | --- | --- |
| `repo` | (required) | Git URL cloned into `/srv/project` |
| `deploy_key` | `keys/<name>` | The repo's deploy key, if it's named differently. Relative to the Gleipnir folder |
| `env_file` | `env/<name>.env` | The project's `.env`, if it's named differently. Relative to the Gleipnir folder |
| `git.name` / `git.email` | none | Your identity for commits made in the VM |
| `vm.memory` / `vm.cpus` | 3072 / 2 | VM resources, in MB / cores |
| `ports.editor` / `ports.app` / `ports.db` | 8080 / 5173 / 54320 | Ports on your computer's `localhost`; each machine needs its own. `db` is only used with PostgreSQL |
| `node` | 24 | Node.js major version |
| `extensions` | Svelte, Tailwind, ESLint, Prettier | Editor extensions to install, by ID from the Open VSX registry |
| `postgres.enabled` | `false` | Install PostgreSQL |
| `postgres.version` | 18 | PostgreSQL major version |
| `postgres.user` / `postgres.password` | `app` / (required) | The database user for your app |
| `postgres.databases` | none | Databases to create, owned by that user |
| `claude.network` | `allowlist` | `allowlist`, or `open` to let Claude reach any site |
| `claude.allowed_domains` | none | Extra sites Claude may reach, by exact name |
| `claude.autocommit` | `true` | Claude works and commits on a `wip/` branch |
| `claude.checks` | `true` | Heimdall's change checks |

Gleipnir refuses to start if two machines use the same port, and tells you which.

## Important: your work lives in the VM

The project isn't on your computer. Until you push, the only copy of your work is inside its VM, and `vagrant destroy` deletes it. Push often. The database lives in the VM too, so `vagrant destroy` deletes its data as well.

## Known gaps

Gleipnir keeps Claude well away from your computer, but inside the machine it isn't sealed:

- **The dev server isn't firewalled.** It runs code Claude can edit, as `dev`, with normal network access.
- **Gjöll works by IP address.** Sites on big shared hosting (Cloudflare, Vercel and similar) share addresses with other sites, so allowing one lets some others through. Keep the list short.
- **DNS lookups aren't restricted**, and can carry small amounts of data out.
- **`.env` protection only covers Claude's file tools.** A shell command run by Claude can still read the file. Keep real production secrets out of these machines.
- **Claude can read and change everything in the project**, including `.git`, and the local database (the password is in `.env`). Use test data, not real personal records.
- **The commit guard and npm setting are guardrails, not locks.** The real protection is that only you merge and push.

## Licence

MIT. See [LICENSE](LICENSE).