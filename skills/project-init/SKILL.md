---
name: project-init
description: Set up a new project from an empty repo, step by step, asking the user what they want (framework, styling, database, testing and so on).
disable-model-invocation: true
---

# Set up a new project

The user has an empty, or almost empty, repo and wants you to set the project up with them. Work through the steps below in order. Ask, don't assume: this is their project.

## 1. Get your bearings

- Read `CLAUDE.md`, and everything in `tmp/context/` if it exists: it's background the user has gathered (what the project is, who it's for, requirements).
- Look at what's already in the repo. If it already has an app in it (a `package.json`, a `src/` folder), stop and ask whether they really want to set it up again.
- Summarise in a few lines what you understand the project to be, and ask about anything that's unclear.

## 2. Ask what they want

Use `AskUserQuestion` for each choice, a few at a time. Recommend options that fit what you learned in step 1, with "(Recommended)" on the first. Cover:

- **Framework:** e.g. SvelteKit, or something else if the project calls for it.
- **Language:** TypeScript or JavaScript.
- **Styling:** e.g. Tailwind CSS, plain CSS, a component library.
- **Database:** none, PostgreSQL, or SQLite; and if one, how it's accessed (e.g. Drizzle, Prisma, plain SQL).
- **Authentication:** none yet, or which approach.
- **Testing:** unit tests (e.g. Vitest) and end-to-end tests (e.g. Playwright).
- **Linting and formatting:** e.g. ESLint and Prettier, with their main settings (indentation, quotes, print width).
- **Deployment target**, if they know it yet (e.g. Node server, a static host). It decides the adapter.

Then show the full plan as a short list and ask them to confirm before you change anything.

## 3. Set it up

Work in the project root. Keep `CLAUDE.md`, `tmp/` and anything else already there.

- Scaffold with the framework's own tool where there is one (e.g. `npx sv create` for SvelteKit), choosing the confirmed options. If it won't run in a folder that isn't empty, scaffold into a temporary folder inside `tmp/` and move the files across.
- Use npm. Install scripts are turned off for you, so if a package needs one to work (e.g. native modules, `prisma generate`), say so and ask the user to run that step in the editor's terminal.
- The `dev` script must start the dev server with the framework's normal command (e.g. `vite dev`). Gleipnir runs it for the user and adds the host and port itself, so don't hard-code them.
- Make sure `.gitignore` covers at least: `node_modules/`, `.env`, `.env.*` (but not `.env.example`), `tmp/`, `.claude-output/`, and the framework's build output.
- Create `.env.example` with every environment variable the app reads, with safe placeholder values. Never write real secrets anywhere.
- If `CLAUDE.md` describes docs files (e.g. `docs/improvements.md`, `docs/deployment.md`, `docs/manual-tests.md`, `docs/environment.md`), create them with their starting layout.
- Fill in the `<…>` placeholders in `CLAUDE.md` (project, stack, commands, environment, conventions) from what was decided, and remove sections that don't apply.
- Run the project's check, lint and test commands once at the end and fix anything that fails.

## 4. What the user has to do

Some things can only be done from the user's computer. List the ones that apply, with the exact steps:

- **Start the dev server:** run `vagrant provision <machine>` on their computer. Gleipnir sets the dev server up once the project has a `dev` script; you can't start it yourself.
- **Database:** in their machine's config (`machines/<machine>.json`), set `postgres.enabled` to `true`, choose a user, password and database name, then provision. Put the matching `DATABASE_URL` in their `.env` file on their computer (`env/<machine>.env`), not in the repo.
- **Playwright:** set `playwright.enabled` to `true` in the machine's config and provision, so the browsers are installed. Don't run `playwright install` yourself.
- **Other environment variables:** add real values to `env/<machine>.env` on their computer, then copy it in with `genv <machine>` (or a full provision).
- **The first push:** the repo had no commits, so there's no `main` branch yet. Once they've reviewed and you've committed, they create it from your branch and push it, in the editor's terminal: `git switch -c main`, then `git push -u origin main`.
- **Sites you couldn't reach:** if anything needed a site outside your allowlist, say which, so they can add it to `claude.allowed_domains` or do that step themselves.

## 5. Finish

Finish as for any request: summarise what was set up, list the changed files, show a commit message (a short subject line, then a few lines on what was set up and why), and ask whether to commit.