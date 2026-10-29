# Gleipnir

A Vagrant VM for running Claude Code safely: the project lives inside the VM, Claude runs as a restricted, firewalled user in its own copy of it, and you review, merge and push from a browser-based editor.

> Gleipnir is an independent project and isn't affiliated with or endorsed by Anthropic. Using Claude Code is subject to Anthropic's terms.

In Norse myth, Gleipnir was the binding that held the giant wolf Fenrir: as thin as a silk ribbon, but impossible to break. Its parts are named from the same story: **Gjöll** is the firewall, **Heimdall** the change checks and **Týr** the managed settings.

## What's in it

- One VM per project, each with its own config, deploy key, `.env` files and context files, and your own starter `CLAUDE.md`
- Your project cloned onto the VM's disk twice: your copy, and a separate one for Claude, where the apps run with Node.js and their npm packages
- Optional PHP and Composer, for Laravel and other PHP apps
- One app per repo, or several in one repo (a monorepo, such as a SvelteKit frontend and a Laravel backend), each with its own folder, `.env` and dev server
- A browser-based editor (code-server)
- The dev servers, running in the background as their own firewalled user
- Claude Code as a restricted user, with a firewall, a proxy that checks every site by name and allows only downloads from package sites, managed settings and change checks
- Claude's work kept on `wip/` branches in its copy, committed only when you say, and brought into yours for you to review, merge and push
- `/project-init`, a guided setup for a brand-new project, and room for your own skills
- Optional PostgreSQL, reachable from your computer
- Optional Playwright browsers

## How it works

- **One Gleipnir folder, one VM per project.** Each file in `machines/` defines a VM, named after the file. Update Gleipnir once and every VM picks it up on its next provision.
- **Each project is separate.** Every VM has its own users, firewall and Claude login, so Claude working on one project can't see another.
- **Your project lives on the VM's own disk**, cloned from its git repo, not shared from your computer. That keeps it fast and keeps project code off your machine.
- **Three users per VM, none with `sudo`:** `dev` for you (the editor, your copy of the project, git and pushing), `claude` for Claude Code, which you start from your own terminal through `vagrant ssh`, and `runner` for the dev servers.
- **Two copies of the project.** Yours, in `/srv/project`, is the one the editor opens and you push from; Claude can't see it. Claude's, in `/srv/work`, is where it works and the apps run. Work moves between them only as git data, checked as it arrives, so nothing Claude writes there (git hooks, git settings, scripts) ever runs as you.
- **Your computer only runs a browser.** Each VM's editor, apps and database are reached on your own `localhost`, through forwarded ports.
- **One entry point:** `install.sh` does all the setup inside a VM, and Vagrant runs it for you.

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
| `env/my-project/` | For a monorepo: one `.env` per app, named after it, such as `env/my-project/backend.env`. Optional (see [Monorepos](#monorepos-several-apps-in-one-repo)) |
| `claude/my-project.md` | A starter `CLAUDE.md` for the project. Optional: falls back to `claude/default.md` (see [Your starter CLAUDE.md](#your-starter-claudemd)) |
| `context/my-project/` | A folder of background files for Claude: briefs, requirements, notes. Optional (see [Project context](#project-context)) |

These folders are ignored by git, so none of your files in them end up in Gleipnir's own repo. To use a file or folder with a different name, give its path in the config with `deploy_key`, `env_file`, `env_dir`, `claude_file` or `context_dir` (see [Configuration](#configuration)).

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

   For a monorepo, start from `machines/monorepo.json.example` instead.

   Set `repo` (the `git@github.com:…` form) and your git name and email. If another machine already uses ports 8080, 5173 or 54320, pick different `ports`. For a database, set `postgres.enabled` to `true` and choose a password (see [The database](#the-database)). For PHP, set `php.enabled` to `true`.

   If the project needs a `.env` file, save it as `env/my-project.env` (or one per app in `env/my-project/`).

3. **Start it:**

   ```bash
   vagrant up my-project
   ```

   Or `gup my-project`, which also saves the output to `logs/` (see [Shortcuts](#shortcuts)).

### Checking it worked

After `vagrant ssh my-project`:

```bash
id dev; id claude; id runner            # claude and runner in group "project"; none in sudo
node -v                                 # the version from the config
php -v; composer --version              # with php.enabled
ls -ld /srv/project /srv/work           # yours (dev), and Claude's (claude, group project)
sudo -u dev git -C /srv/project status  # your copy: a clean working tree
devserver                               # the dev servers: active (running)
sudo -u claude curl -s --max-time 3 http://127.0.0.1:8080 || echo blocked   # Claude can't reach the editor
sudo -u claude getent hosts example.com || echo blocked                     # Claude can't look names up
sudo -u runner getent hosts example.com || echo blocked                     # nor can the dev servers
sudo gjoll-firewall --verify            # Gjöll's own checks, including the proxy
```

## Using the editor

Open `http://localhost:8080` in Chrome or Firefox (or the `ports.editor` you chose). There's no password: only your computer can reach that port, and Gjöll stops Claude connecting to the editor from inside the machine.

The editor runs as the `dev` user and opens your copy of the project, in `/srv/project`. Its built-in terminal is a shell as `dev`, for reviewing Claude's branches, merging, committing and pushing. Use the Source Control view to review changes and commit.

The apps run from Claude's copy, not yours, and that's where packages are installed and tests run: ask Claude. **Don't install packages or run the project's code in your copy.** It could include code Claude wrote, and in your copy it would run as you, with your deploy key and the editor.

Claude Code isn't run from the editor; see [Using Claude Code](#using-claude-code).

Safari on older macOS versions can struggle with the editor; a current Chrome or Firefox works best.

## The dev servers

Each app's dev server runs in the background from Claude's copy of the project, as its own user, `runner`. It starts when the machine boots, restarts if it crashes, and reloads as Claude changes files. It's behind Gjöll like Claude: it can reach the machine itself (the database, the other apps) and only the sites you list in `runner.allowed_domains`, none by default. It can't see your copy of the project, your home folder or the editor. For a project with one app, the app is at `http://localhost:5173` (or the `ports.app` you chose); in a monorepo, each app is at its own port (see [Monorepos](#monorepos-several-apps-in-one-repo)).

Gleipnir works out what to run from what's in each app's folder:

- **A JavaScript app** with a `dev` script in its `package.json` runs `npm run dev`, told to listen on the app's port.
- **A Laravel app** (with `artisan` and `composer.json`) runs `php artisan serve` on the app's port.

For anything else, set `devserver.command` (or an app's own `devserver.command`). It must listen on all of the machine's addresses (`0.0.0.0`) and on the app's port; both are in its environment as `$HOST` and `$PORT`.

An app with nothing to run yet, such as a brand-new project with no `package.json`, has no dev server; that's expected. Once it has one, run `vagrant provision my-project` to set it up.

Control them from the editor's terminal, or from your computer with `vagrant ssh my-project -c "devserver restart"`:

```bash
devserver                    # are they running?
devserver restart            # all of them, after installing packages or changing config
devserver restart backend    # just one app
devserver stop               # until the next start or reboot
devserver start
devserver log                # the end of their output
devserver log -f frontend    # follow one app's output (Ctrl+C to stop)
devserver list               # each app's folder, port and command
```

Claude can read their output, to check for build errors, but can't start or stop them.

## Monorepos: several apps in one repo

A monorepo keeps related apps in one repo, each in its own folder, such as a SvelteKit frontend in `frontend/` and a Laravel API in `backend/`. List them under `apps` in the machine's config, each with its own port:

```json
"php": { "enabled": true, "version": "8.4" },
"apps": {
  "frontend": { "port": 5174 },
  "backend": { "port": 8001 }
}
```

- **Each app's folder** is named after it, unless you give a `path` (such as `"path": "apps/web"`). It can be `"."`, the repo's root, for one of them.
- **Each app's port is the same inside the machine and on your computer.** So `http://localhost:8001` reaches the backend from your browser, from the frontend's dev server inside the machine, and from Claude, and the frontend can call the API at the same address everywhere. Each port must be unique across all your machines, and `ports.app` isn't used.
- **Each app has its own `.env`**, copied from `env/my-project/<app>.env` on your computer into the app's folder (see [The .env files](#the-env-files)).
- **Each app's packages** (npm, and Composer for PHP apps) are installed in its folder in Claude's copy when the machine is first set up, as `claude`, behind Gjöll. After that, Claude installs them.
- **Each app has its own dev server**, controlled with `devserver <command> <app>`.

An app's folder doesn't have to exist yet: on a new repo, `/project-init` creates each app in its folder. Provision again afterwards to copy in their `.env` files and start their dev servers.

## PHP and Composer

With `php.enabled` set to `true`, the machine installs PHP (8.4 by default, from the [ondrej/php](https://launchpad.net/~ondrej/+archive/ubuntu/php) package archive) and Composer. Only the command-line PHP is installed, with the extensions Laravel needs, plus PostgreSQL, SQLite and image support; add others with `php.extensions`, such as `["redis"]`. Change `php.version` and provision to switch versions.

Claude runs Composer itself, as it does npm: Composer's catalogue (Packagist) and GitHub, where most packages are downloaded from, are on its list. Only downloads are allowed from them (see [What holds Claude in place](#what-holds-claude-in-place)). Composer never runs a package's own scripts: only those in your `composer.json`, and plugins it explicitly allows, and Heimdall flags changes to that file.

## Playwright

With `playwright.enabled` set to `true`, the machine installs Playwright's browsers (Chromium by default) and the system libraries they need. Your tests, and Claude, can then run them with `npx playwright test`.

- **The browsers match your project's Playwright version** (in a monorepo, the first app that has Playwright). After upgrading Playwright in the project, run `vagrant provision my-project` to install the matching browsers.
- **They're shared and read-only**, in `/opt/playwright`. Claude and the dev servers use them, and neither can change them, so don't run `npx playwright install`; provisioning does it.
- **They run headless**, since the machine has no screen. To see a test report, ask Claude to run `npx playwright show-report` in the background, then open `http://localhost:8080/proxy/9323/` (the editor passes it through).
- **Reuse the dev server.** It's already running on the app's port (5173 for a project with one app), so in `playwright.config` point `webServer.url` at `http://localhost:<port>` with `reuseExistingServer: true`, or leave `webServer` out.

## The database

With `postgres.enabled` set to `true`, the machine runs PostgreSQL (version 18 by default) with a user and the databases listed in `postgres.databases`. Provisioning again adds any new databases; it never drops or changes existing ones.

Inside the machine, the apps, tests and Claude connect to `127.0.0.1:5432`. Point your `.env` there:

```
DATABASE_URL=postgres://app:change-me@127.0.0.1:5432/my_project
```

or, for Laravel:

```
DB_CONNECTION=pgsql
DB_HOST=127.0.0.1
DB_PORT=5432
DB_DATABASE=my_project
DB_USERNAME=app
DB_PASSWORD=change-me
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

### The `.env` files

`env/my-project.env` is copied to `/srv/work/.env` (Claude's copy, where the apps run), and in a monorepo each `env/my-project/<app>.env` to that app's folder, on every provision, readable by Claude's tools and the dev servers only. **The copies on your computer win:** changes made inside the machine are overwritten. An app whose folder doesn't exist yet gets its `.env` on the first provision after it does.

**Keep production secrets out of these files.** Claude's file tools can't read `.env` files, but code Claude runs (tests, scripts, a package it installed) can, so use development values only: a local database password, test API keys and so on.

After editing them, copy just those files across, which takes a few seconds instead of a full provision and restarts the dev servers so they pick up the change:

```bash
vagrant provision --provision-with env-upload,env-upload-apps,env my-project
```

With the [shortcuts](#shortcuts) installed, that's just `genv my-project`.

## Project context

Put background material for Claude (briefs, requirements, notes, designs) in `context/my-project/` on your computer. It's copied into the machine as `/srv/context` on every provision, so it's always there, even after a rebuild:

- **Your computer's copy wins.** The folder is replaced each time, so files you remove are removed in the machine too.
- **Claude can read it but not change it.** Claude's instructions tell it where it is, and your starter `CLAUDE.md` can tell Claude to read it when getting started.
- **It never goes into git.** It's outside both copies of the project.

After adding or changing files, copy just the folder across:

```bash
vagrant provision --provision-with context-upload,context my-project
```

With the [shortcuts](#shortcuts) installed, that's just `gctx my-project`.

## Using Claude Code

Start Claude from a terminal on your computer:

```bash
vagrant ssh my-project
claude
```

Or in one step: `vagrant ssh my-project -- -t claude`. The first time, Claude Code shows a login link: open it in your browser, sign in, and paste the code back.

The `claude` command:

1. Checks that **Gjöll**, the firewall, is up, and refuses to start if it isn't.
2. Brings your latest branches into Claude's copy, where Claude sees them as `trusted/<branch>`, such as `trusted/main`.
3. Puts Claude on a `wip/<date>` branch, started from your current branch (usually `main`), so Claude's work stays off it. On the same day, Claude carries on with the branch it has.
4. Takes a snapshot for **Heimdall**, then starts Claude Code as the restricted `claude` user, in `/srv/work`.
5. When you exit Claude, prints Heimdall's summary of anything changed that can run code, and anything Gjöll blocked, then brings Claude's branch into your copy for review.

### Reviewing and merging Claude's work

Claude doesn't commit on its own. When it finishes a request, it summarises the changes, shows the commit message it would use, and asks. Tell Claude to commit (or ask for changes first). Its commits go on its `wip/` branch; it can't commit to `main`, and can't push.

When you exit Claude, its branch arrives in your copy of the project under the same name, and the `claude` command tells you how many commits and files changed, with Heimdall's check of what the branch changes. To bring it across in the middle of a session, run `greview my-project` on your computer (or `sudo gleipnir-review` after `vagrant ssh`). Only committed work comes across; it tells you if Claude's copy has uncommitted changes too.

Review and merge it in the editor's terminal, or in the Source Control view:

```bash
git diff main...wip/2026-10-29        # everything on the branch
git merge --squash wip/2026-10-29     # all of it as one change, on main
git commit                            # write the final message
git push
git branch -D wip/2026-10-29
```

Keep `main` checked out: a branch you have checked out can't be updated with Claude's latest work. Your commits on `main` reach Claude at the start of its next session, as `trusted/main`.

### Claude's instructions

`claude-instructions.md`, in the Gleipnir folder, is what Claude is told at the start of every session: how the machine works, its apps and dev servers, and the git rules above. Edit it there, then run `vagrant provision my-project`; every machine gets your version on its next provision, as a root-owned `/etc/claude-code/CLAUDE.md` that Claude can't change.

Sections wrapped in `{{if ...}}` and `{{end}}` only appear on machines they apply to, such as the Playwright note when `playwright.enabled` is on. The comment at the top of the file lists them. To check what a machine's Claude actually gets:

```bash
vagrant ssh my-project -c "cat /etc/claude-code/CLAUDE.md"
```

A project can also have its own `CLAUDE.md` in its repo, for notes about that project. Claude reads both.

### Your starter CLAUDE.md

To give every new project your own way of working (how you like to plan, test, write code and get asked questions), write it once as a starter `CLAUDE.md`:

```bash
cp claude/example.md.example claude/default.md
```

Edit it to suit you. Use `claude/default.md` for every project, or `claude/my-project.md` for one machine (it takes priority).

It's copied into Claude's copy of the project as `CLAUDE.md` **once, when the machine is first set up**, and only if the project doesn't already have one. After that it belongs to the project: Gleipnir never overwrites it. Claude commits it with its first work, so it reaches your copy, and the repo, when you merge. To bring a later version of your starter into an existing project, commit it in your copy; Claude gets it at the start of its next session.

### Skills

Skills are commands you can run inside Claude, like `/project-init`. Gleipnir's live in `skills/` in the Gleipnir folder, one folder per skill with a `SKILL.md` in it, and every machine gets them on its next provision, replacing any changes made inside the machine. Edit them, or add your own, there.

**`/project-init`** sets up a new project from an empty repo. Start Claude in the new machine and run it: Claude reads your `CLAUDE.md` and the context folder, asks what you want (framework, styling, database, testing and so on), confirms the plan, then sets it all up and fills in your `CLAUDE.md`. In a monorepo it sets up each app in its own folder. At the end it lists anything only you can do from your computer, such as turning on PostgreSQL or Playwright in the machine's config, adding each app's `.env`, and provisioning to start the dev servers.

A brand-new repo has no `main` branch until its first commit. Once Claude has committed its setup and you've exited Claude, its branch is in your copy: review it, then create `main` from it and push, in the editor's terminal:

```bash
git switch -c main wip/2026-10-29
git push -u origin main
```

### What holds Claude in place

- **The `claude` user** has no `sudo`, and can't read `dev`'s home (so your git key is out of its reach) or your copy of the project.
- **Two copies of the project.** Claude works in its own. Its work reaches yours only as git data (a bundle of its branch, each object checked as it arrives), so no git hook, git setting or script Claude writes ever runs as you. Gleipnir never runs git in Claude's copy as you either, and Heimdall only reads files there.
- **The dev servers** run Claude's code, so they run as their own user, `runner`, behind Gjöll with an empty list of sites, and can't see your copy, your home folder or the editor. You can start and stop them; they can't.
- **Týr**, the managed settings in `/etc/claude-code/`, are owned by root and override any user or project settings. They block Claude's file tools from `.env` files, turn off non-essential traffic and Claude's commit attribution, keep your claude.ai connectors (Drive, Gmail and so on) and plugins out of the machine, and run Heimdall's checks. Claude also gets a root-owned `CLAUDE.md` made from `claude-instructions.md` (see above).
- **Gjöll** limits the `claude` user to Anthropic, the package sites (npm's registry, and with PHP, Packagist and GitHub's package downloads) and the sites you list in `claude.allowed_domains`, in two parts:
  - **A firewall** that lets `claude` reach only the machine itself (the dev servers, the database) and one port on a local proxy, and `runner` the same with a port of its own. Neither has DNS, so they can't look names up, or carry data out inside lookups. It also stops them connecting to the editor, which would give them a terminal as `dev`.
  - **A proxy (Squid)** that checks every connection by the site's **name**, not its address: first the name the tool asks for, then the name inside the encrypted connection's opening message. Checking names matters because big hosting networks (Cloudflare and similar) serve thousands of sites from the same addresses, so allowing an address would allow them all.

  Most connections, including everything to Anthropic, are never decrypted: the proxy reads the names and passes the rest through untouched. **The package sites are the exception.** The proxy decrypts them and checks each request, so packages can be downloaded but nothing can be uploaded through them: no publishing a package, no gists or issues on GitHub, nothing but GitHub's package downloads at all. (The only uploads let through are npm's and Packagist's security checks, which send a list of package names to a service only they can read.) To do that, each machine makes its own certificate authority for the proxy. Its private key is readable only by root and the proxy, and only the tools Claude runs trust it, through settings Claude gets automatically; the rest of the machine doesn't.

  Tools find the proxy through the standard `HTTPS_PROXY` setting, which Claude gets automatically. A tool that ignores it can't connect at all, rather than going round. Claude won't start if the firewall or the proxy isn't running. The proxy and the database server are firewalled too: the proxy can only make HTTPS connections, and PostgreSQL can't connect out at all.
- **Heimdall** flags changes to package scripts, tool configs and shell scripts, npm and Composer package changes in every app (watch for look-alike names), and new or changed git hooks and settings that run commands: after each turn, and in a summary when you exit. In Claude's copy it only reads files, and says so if it couldn't see everything (a folder it can't read, a link, a huge file). When Claude's branch arrives in your copy, it checks the branch's commits too: that's what you'd merge, whatever Claude's files look like.
- **npm install scripts** are off by default for the `claude` user, including for the packages installed when the machine is set up.
- **Git hooks** for Claude's commits: they must go on a `wip/` branch, and their messages can't credit Claude or Anthropic (no trailer, such as `Co-Authored-By:`, that mentions either, and no "Generated with Claude Code" lines).

To let Claude reach another site, add it to `claude.allowed_domains` and run `vagrant provision my-project`; for the dev servers, use `runner.allowed_domains`. A name like `docs.example.com` allows just that site; `.example.com` (or `*.example.com`) allows `example.com` and everything under it. Avoid wildcards over a package site's neighbours: `.github.com`, for example, would also let Claude reach the rest of GitHub, uploads included (provisioning warns you). Setting `claude.network` to `"open"` removes the allowlist and the proxy entirely, for Claude and the dev servers; their connections are then logged (`sudo journalctl -k | grep gjoll`). Use it only on machines with nothing sensitive in them.

#### Seeing what was blocked

When you exit Claude, the `claude` command lists anything Gjöll blocked during the session. To look at any time:

```bash
sudo gjoll-log                 # the last 24 hours
sudo gjoll-log --since 2h      # or 30m, 3d
```

It shows four kinds of block:

- **Sites that aren't on the list**, usually documentation Claude tried to read. Add it if you want.
- **Connections that named one site, then another** in the encrypted connection's opening message.
- **Requests refused inside a package site**: an upload, or a request for a different site.
- **Attempts to go round the proxy**, including name lookups (DNS). Gjöll's own test that Claude can't look names up is left out.

Only the first should happen in normal use. Any upload to a package site, and names you don't recognise (such as a long random string in front of a domain), are worth a closer look.

## Everyday commands

```bash
vagrant status                # every machine and whether it's running
vagrant up my-project         # start one (a bare `vagrant up` starts none)
vagrant ssh my-project
vagrant halt my-project
vagrant provision my-project  # apply config changes or a Gleipnir update
genv my-project               # copy just the .env files across (a shortcut: see below)
gctx my-project               # copy just the context folder across (a shortcut: see below)
greview my-project            # bring Claude's branch into your copy (a shortcut: see below)
vagrant reload my-project     # restart it; needed after changing ports or apps
vagrant ssh my-project -c "devserver restart"   # restart the dev servers
```

To update Gleipnir itself: `git pull` in this folder, then `vagrant provision <name>` for each running machine.

## Shortcuts

A few shell commands save typing, and work from any folder. To add them, run this once from the Gleipnir folder, then open a new terminal:

```bash
./install-shortcuts
```

They go in your shell's startup file: `~/.zshrc` if your terminal uses zsh (the macOS default), or `~/.bash_profile` if it uses bash. `echo $SHELL` tells you which.

| Shortcut | Does |
| --- | --- |
| `gup my-project` | Start a machine (`vagrant up`), saving the output to `logs/` |
| `gprov my-project` | Provision a machine again, saving the output to `logs/` |
| `genv my-project` | Copy just the `.env` files across, and restart the dev servers (see [The .env files](#the-env-files)) |
| `gctx my-project` | Copy just the context folder across (see [Project context](#project-context)) |
| `gssh my-project` | Log in to a machine (`vagrant ssh`) |
| `greview my-project` | Bring Claude's current branch into your copy of the project, for review. Name a branch to bring another: `greview my-project wip/2026-10-28` |
| `ghalt my-project` | Shut a machine down (`vagrant halt`) |
| `gdestroy my-project` | Delete a machine (`vagrant destroy`), after a reminder of what's lost. Vagrant still asks you to confirm |

Each `gup` and `gprov` run gets its own log, named after the machine and the time, such as `logs/my-project-2026-10-29-134502.log`. `logs/` is ignored by git, since the output includes your machine's details.

Run `./install-shortcuts` again after moving the Gleipnir folder, or after updating Gleipnir: it updates the shortcuts rather than adding them twice. It only changes its own block in the file, and keeps the previous version alongside it (for example `~/.zshrc.gleipnir-backup`). If you already have aliases or functions with the same names, it asks you to remove them first. Use `--file` for a different file, or `--remove` to take them out.

## Configuration

Each `machines/<name>.json` file supports:

| Field | Default | What it sets |
| --- | --- | --- |
| `repo` | (required) | Git URL cloned into `/srv/project`, your copy. Claude's copy is made from yours |
| `deploy_key` | `keys/<name>` | The repo's deploy key, if it's named differently. Relative to the Gleipnir folder |
| `env_file` | `env/<name>.env` | The project's `.env`, if it's named differently. Relative to the Gleipnir folder |
| `env_dir` | `env/<name>/` | The folder of each app's `.env`, if it's named differently. Relative to the Gleipnir folder |
| `claude_file` | `claude/<name>.md`, then `claude/default.md` | A starter `CLAUDE.md`, if it's named differently. Relative to the Gleipnir folder |
| `context_dir` | `context/<name>/` | The project's context folder, if it's named differently. Relative to the Gleipnir folder |
| `git.name` / `git.email` | none | Your identity for commits made in the VM |
| `vm.memory` / `vm.cpus` | 3072 / 2 | VM resources, in MB / cores |
| `ports.editor` / `ports.app` / `ports.db` | 8080 / 5173 / 54320 | Ports on your computer's `localhost`; each machine needs its own. `app` isn't used with `apps`; `db` is only used with PostgreSQL |
| `node` | 24 | Node.js major version |
| `php.enabled` | `false` | Install PHP and Composer |
| `php.version` | `8.4` | PHP version, such as `8.3`, `8.4` or `8.5` |
| `php.extensions` | none | Extra PHP extensions, such as `["redis"]` |
| `apps` | one app, the whole repo | For a monorepo: each app by name, with its `port` (required, the same inside the machine and on your computer), `path` (its folder; defaults to its name) and `devserver` (`enabled`, `command`) |
| `devserver.enabled` | `true` | Run the dev servers in the background |
| `devserver.command` | worked out from the project | The command that starts the dev server (for a project with one app). It must listen on `$HOST` and `$PORT` |
| `playwright.enabled` | `false` | Install Playwright's browsers |
| `playwright.browsers` | `["chromium"]` | Which browsers: `chromium`, `firefox`, `webkit` |
| `extensions` | Svelte, Tailwind, ESLint, Prettier | Editor extensions to install, by ID from the Open VSX registry |
| `postgres.enabled` | `false` | Install PostgreSQL |
| `postgres.version` | 18 | PostgreSQL major version |
| `postgres.user` / `postgres.password` | `app` / (required) | The database user for your app |
| `postgres.databases` | none | Databases to create, owned by that user |
| `claude.network` | `allowlist` | `allowlist`, or `open` to let Claude reach any site |
| `claude.allowed_domains` | none | Extra sites Claude may reach: `docs.example.com` for that site only, `.example.com` for it and everything under it |
| `runner.allowed_domains` | none | Sites the dev servers may reach, in the same form. With `claude.network` set to `open`, they can reach any site |
| `claude.wip_branch` | `true` | Claude works on a `wip/` branch, and commits there only when you say. Off: Claude may commit on any branch, which arrives in your copy as `claude/<branch>`. (Formerly `claude.autocommit`, which still works) |
| `claude.checks` | `true` | Heimdall's change checks |

Gleipnir refuses to start if two machines, or two apps, use the same port, and tells you which.

## Important: your work lives in the VM

The project isn't on your computer. Until you push, the only copy of your work is inside its VM (your commits in your copy, Claude's in its own), and `vagrant destroy` deletes it. Push often. The database lives in the VM too, so `vagrant destroy` deletes its data as well. Gleipnir makes you name the machine (`vagrant destroy my-project`), so a bare `vagrant destroy` can't wipe every machine at once.

## Known gaps

Gleipnir keeps Claude well away from your computer, but inside the machine it isn't sealed:

- **The dev servers run Claude's code.** They're firewalled and can't touch your copy, but they share Claude's copy, the database and the machine's local ports with Claude.
- **Merging is how Claude's code reaches you.** Review a branch before you merge it, and never install packages or run the project's code in your copy.
- **Gjöll checks names, and only looks inside the package sites' connections.** Some hosting networks let a connection name one of their sites at the start and then ask for another inside the encryption ("domain fronting"); many big networks refuse this now, but not all. Where a network still allows it, a connection that names a site the proxy passes through (such as one of Anthropic's) could reach another site on the same network, a package site included, without being checked. A connection that gives no name at the start is judged by the name it asked the proxy for.
- **Sites you allow are allowed for anything,** uploads included, unlike the package sites. Code Claude runs could send data to a site on the list, such as an API, using someone else's account there. Keep the list short.
- **Anthropic's own API is a way out too.** It has to be reachable for Claude Code to work, and it can't be limited to your account. Code Claude runs could send data there using someone else's Anthropic account. That's another reason to keep anything sensitive out of the machine.
- **`.env` protection only covers Claude's file tools.** A shell command run by Claude can still read the files. Keep real production secrets out of these machines.
- **Claude can read and change everything in its copy of the project**, including its `.git`, and the local database (the password is in `.env`). Use test data, not real personal records.
- **The commit guards and npm setting are guardrails, not locks.** The real protection is that only you merge and push.

## Licence

MIT. See [LICENSE](LICENSE).