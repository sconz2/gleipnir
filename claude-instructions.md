<!--
  Claude's instructions for every Gleipnir machine. Provisioning turns this file
  into /etc/claude-code/CLAUDE.md, which Claude reads at the start of each session
  and can't change. Edit it here, then run: vagrant provision <machine>

  Lines between {{if ...}} and {{end}} are only kept when that's true for the machine:
    {{if wip_branch}} / {{if not wip_branch}}           claude.wip_branch is on / off
    {{if network=allowlist}} / {{if network=open}}      claude.network
    {{if playwright}}                                   playwright.enabled is on
    {{if php}}                                          php.enabled is on
    {{if apps}}                                         the config lists "apps" (a monorepo)
    {{if devserver}}                                    at least one dev server is set up
    {{if context}}                                      a context folder is copied into the machine
  A line that's just {{apps}} becomes the list of apps (folder and port), and one that's
  just {{devservers}} the list of dev servers (command and port).
  {{php_version}} becomes the PHP version.
  This comment isn't included.
-->
# Gleipnir environment

You're running inside a Gleipnir VM, as the `claude` user.

- The project is in /srv/work: your own copy of it. The user works in a separate copy that you can't see or change; your commits reach it when they bring your branch across to review, which happens when your session ends. You have no sudo.
- The editor on port 8080 belongs to the user, and you can't connect to it.
{{if network=allowlist}}
- Your network access is limited to an allowlist. Everything goes through a proxy that checks each site by name, and you can't look names up (no DNS). If you need a site that isn't reachable, say so rather than working around it.
- Tools reach the proxy through `HTTPS_PROXY`, which is already set; don't change or unset it, or the certificate settings next to it. Errors like "could not resolve host" or `ENOTFOUND` usually mean the tool isn't using the proxy, not that the site is down: look for the tool's own proxy setting, or tell the user. A 403 from the proxy (in Node's `fetch`: "Request was cancelled") means the site isn't on the list.
- The package sites (npm's registry, and Composer's when PHP is set up) only allow downloads: installing packages works, but nothing can be published or uploaded. A certificate error from a package site means the tool isn't using the machine's certificate settings (`SSL_CERT_FILE`, `NODE_EXTRA_CA_CERTS`); tell the user rather than turning certificate checks off.
{{end}}
{{if network=open}}
- Your network connections are logged.
{{end}}
{{if php}}
- PHP {{php_version}} and Composer are installed. Run Composer yourself (`composer require`, `composer install`); packages come from Packagist and GitHub, download only.
{{end}}
{{if context}}
- /srv/context holds background files from the user (briefs, requirements, notes). It's read-only for you and replaced from the user's computer on each provision, so don't try to change it.
{{end}}
{{if playwright}}
- Playwright's browsers are installed in /opt/playwright. Don't run `playwright install`; if a browser is missing, say so.
{{end}}
{{if apps}}

## Apps

The project is a monorepo. Each app has its own folder, `.env`, packages and dev server:

{{apps}}

- Run each app's commands (npm, Composer, artisan, tests) in its own folder.
- Each app's `.env` is copied in from the user's computer. If an app's folder doesn't exist yet, it hasn't been created: /project-init sets it up.
- An app's port is the same inside this machine and on the user's computer, so `http://localhost:<port>` reaches it from either, e.g. the frontend calling the backend's API.
{{end}}
{{if devserver}}

## Dev servers

{{devservers}}

- They run from your copy of the project, as a separate `runner` user, and reload as you edit. They can't reach sites outside the machine unless the user has listed them.
- They belong to the user: don't start, stop or restart them. If one needs restarting (after a dependency or config change), ask the user to run `devserver restart` (or `devserver restart <app>` for one).
- Their output is in /var/log/gleipnir/ (`devserver log` shows the end of it, `devserver log <app>` one app's). Read it to check for errors.
{{end}}
{{if wip_branch}}

## Git

- Work on the current `wip/` branch. Never commit to `main`, and never push.
- `trusted/main` (and the other `trusted/` branches) are the user's branches as they were when this session started. Compare your work with those, not with a local `main`, which may be out of date.
- Don't change git's own settings or hooks (`.git/config`, `.git/hooks`); the user is shown any change to them.
- Never commit on your own. When you've finished a request, stop and:
  1. Summarise what you changed.
  2. Show the commit message you'd use: a short subject line, then a few lines on what changed and why.
  3. Ask whether to commit.
- Only commit when the user tells you to, using that message or their edited version. If they ask for more changes first, make them, then show an updated message and ask again.
- Don't add Co-Authored-By lines or any other attribution to commit messages.
{{end}}
{{if not wip_branch}}

## Git

- Never commit or push on your own. When you've finished a request, summarise what you changed and suggest a commit message. Only what you commit reaches the user's copy (when your session ends, your branch arrives there as `incoming/<branch>`).
- `trusted/main` (and the other `trusted/` branches) are the user's branches as they were when this session started. Compare your work with those, not with a local `main`, which may be out of date.
- Don't change git's own settings or hooks (`.git/config`, `.git/hooks`); the user is shown any change to them.
- Don't add Co-Authored-By lines or any other attribution to commit messages.
{{end}}