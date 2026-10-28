<!--
  Claude's instructions for every Gleipnir machine. Provisioning turns this file
  into /etc/claude-code/CLAUDE.md, which Claude reads at the start of each session
  and can't change. Edit it here, then run: vagrant provision <machine>

  Lines between {{if ...}} and {{end}} are only kept when that's true for the machine:
    {{if wip_branch}} / {{if not wip_branch}}           claude.wip_branch is on / off
    {{if network=allowlist}} / {{if network=open}}      claude.network
    {{if playwright}}                                   playwright.enabled is on
    {{if devserver}}                                    the dev server is set up
    {{if context}}                                      a context folder is copied into the project
  {{devserver_command}} becomes the dev server's command.
  This comment isn't included.
-->
# Gleipnir environment

You're running inside a Gleipnir VM, as the `claude` user.

- The project is in /srv/project. You have no sudo.
- The editor on port 8080 belongs to the user, and you can't connect to it.
{{if network=allowlist}}
- Your network access is limited to an allowlist. If you need a site that isn't reachable, say so rather than working around it.
{{end}}
{{if network=open}}
- Your network connections are logged.
{{end}}
{{if context}}
- `tmp/context/` in the project holds background files from the user (briefs, requirements, notes). It's read-only for you and replaced from the user's computer on each provision, so don't try to change it.
{{end}}
{{if playwright}}
- Playwright's browsers are installed in /opt/playwright. Don't run `playwright install`; if a browser is missing, say so.
{{end}}
{{if devserver}}

## Dev server

- It runs `{{devserver_command}}` as the `dev` user, on port 5173, and reloads as you edit.
- It belongs to the user: don't start, stop or restart it. If it needs restarting (after a dependency or config change), ask the user to run `devserver restart`.
- Its output is in /var/log/gleipnir/devserver.log (`devserver log` shows the end of it). Read it to check for build errors.
{{end}}
{{if wip_branch}}

## Git

- Work on the current `wip/` branch. Never commit to `main`, and never push.
- Never commit on your own. When you've finished a request, stop and:
  1. Summarise what you changed.
  2. Show the commit message you'd use: a short subject line, then a few lines on what changed and why.
  3. Ask whether to commit.
- Only commit when the user tells you to, using that message or their edited version. If they ask for more changes first, make them, then show an updated message and ask again.
- Don't add Co-Authored-By lines or any other attribution to commit messages.
{{end}}
{{if not wip_branch}}

## Git

- Never commit or push on your own. When you've finished a request, summarise what you changed and suggest a commit message.
- Don't add Co-Authored-By lines or any other attribution to commit messages.
{{end}}