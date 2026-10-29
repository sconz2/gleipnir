---
name: project-init
description: Set up a new project from an empty repo, step by step, asking the user what they want (framework, styling, database, testing and so on). Handles a single app or a monorepo with several apps.
disable-model-invocation: true
---

# Set up a new project

The user has an empty, or almost empty, repo and wants you to set the project up with them. Work through the steps below in order. Ask, don't assume: this is their project.

## 1. Get your bearings

- Read `CLAUDE.md`, and everything in `/srv/context/` if it exists: it's background the user has gathered (what the project is, who it's for, requirements).
- Check your instructions for an **Apps** section. If there is one, the project is a monorepo: each app listed there gets its own folder, port and dev server, and you set up each one in its folder. If there isn't, the whole repo is one app.
- Look at what's already in the repo. If an app is already there (a `package.json`, a `composer.json`, a `src/` folder), stop and ask whether they really want to set it up again.
- Summarise in a few lines what you understand the project to be, and ask about anything that's unclear.

## 2. Ask what they want

Use `AskUserQuestion` for each choice, a few at a time. Recommend options that fit what you learned in step 1, with "(Recommended)" on the first. For each app, cover what applies:

- **Framework:** e.g. SvelteKit for a frontend, Laravel for a PHP backend or API.
- **Language:** TypeScript or JavaScript (for a JavaScript app).
- **Styling:** e.g. Tailwind CSS, plain CSS, a component library.
- **Database:** none, PostgreSQL, or SQLite; and if one, how it's accessed (e.g. Drizzle or Prisma for SvelteKit; Eloquent for Laravel). In a monorepo, usually only the backend talks to the database.
- **Authentication:** none yet, or which approach (e.g. Laravel Sanctum for a SvelteKit frontend with a Laravel API).
- **Testing:** e.g. Vitest and Playwright for a frontend; Pest or PHPUnit for Laravel.
- **Linting and formatting:** e.g. ESLint and Prettier, Laravel Pint, with their main settings (indentation, quotes, print width).
- **Deployment target**, if they know it yet (e.g. Node server, a static host, a PHP host). It decides the adapter.

In a monorepo, also ask how the apps talk to each other (e.g. the frontend calls the backend's API at `http://localhost:<backend port>`, which works both inside the machine and on their computer).

Then show the full plan as a short list and ask them to confirm before you change anything.

## 3. Set it up

Work in the project root, or in each app's folder in a monorepo. Keep `CLAUDE.md`, `tmp/` and anything else already there.

- Scaffold with the framework's own tool where there is one:
  - SvelteKit: `npx sv create <folder>`, choosing the confirmed options.
  - Laravel: `composer create-project laravel/laravel <folder>` (only if PHP is installed; see your instructions).
- If a tool won't run in a folder that isn't empty, scaffold into a temporary folder inside `tmp/` and move the files across. Never overwrite an existing `.env`: Gleipnir copies the real one in from the user's computer.
- Use npm and Composer. npm's install scripts are turned off by default, so if a package needs one to work (e.g. native modules, `prisma generate`), say which package and why, and only once the user agrees run it yourself (`npm rebuild <package> --ignore-scripts=false`, or the step's own command).
- Dev servers: Gleipnir runs them for the user and adds the host and port itself. For a JavaScript app, the `dev` script must start the dev server with the framework's normal command (e.g. `vite dev`), without a host or port. For Laravel, Gleipnir runs `php artisan serve` itself.
- Make sure each `.gitignore` covers at least: `node_modules/`, `vendor/`, `.env`, `.env.*` (but not `.env.example`), `tmp/`, `.claude-output/`, and the framework's build output. A monorepo can have one at the root for shared entries and one per app.
- Create a `.env.example` for each app with every environment variable it reads, with safe placeholder values. Never write real secrets anywhere.
- Laravel needs an `APP_KEY`. Run `php artisan key:generate --show` to make one, and give it to the user for their `.env` file (it's a development key; don't put it in the repo).
- If `CLAUDE.md` describes docs files (e.g. `docs/improvements.md`, `docs/deployment.md`, `docs/manual-tests.md`, `docs/environment.md`), create them with their starting layout.
- Fill in the `<…>` placeholders in `CLAUDE.md` (project, stack, commands, environment, conventions) from what was decided, and remove sections that don't apply. In a monorepo, give each app its own commands.
- Run each app's check, lint and test commands once at the end and fix anything that fails.

## 4. What the user has to do

Some things can only be done from the user's computer. List the ones that apply, with the exact steps:

- **Start the dev servers:** run `vagrant provision <machine>` (or `gprov <machine>`) on their computer. Gleipnir sets each app's dev server up once its folder has what it needs; you can't start them yourself.
- **Each app's `.env`:** in a monorepo, one file per app on their computer, named after the app: `env/<machine>/<app>.env` (e.g. `env/<machine>/backend.env`). For a single app, `env/<machine>.env`. Put the values from `.env.example` in it with real development values, then copy them in with `genv <machine>` (or a full provision).
- **Database:** in their machine's config (`machines/<machine>.json`), set `postgres.enabled` to `true`, choose a user, password and database name, then provision. Put the matching settings (e.g. `DATABASE_URL`, or Laravel's `DB_*` values) in the app's `.env` file on their computer, not in the repo.
- **PHP:** if they want a Laravel app but PHP isn't installed, set `php.enabled` to `true` in the machine's config and provision, then run /project-init again.
- **Playwright:** set `playwright.enabled` to `true` in the machine's config and provision, so the browsers are installed. Don't run `playwright install` yourself.
- **The first push:** the repo had no commits, so there's no `main` branch yet. Once you've committed, your branch arrives in their copy of the project when this session ends (as `wip/<date>`). They review it, then create `main` from it and push it, in the editor's terminal: `git switch -c main wip/<date>`, then `git push -u origin main`.
- **Sites you couldn't reach:** if anything needed a site outside your allowlist, say which, so they can add it to `claude.allowed_domains` or do that step themselves.

## 5. Finish

Finish as for any request: summarise what was set up, list the changed files, show a commit message (a short subject line, then a few lines on what was set up and why), and ask whether to commit.