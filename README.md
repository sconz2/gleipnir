# Gleipnir

A Vagrant VM for running Claude Code safely: the project lives inside the VM, Claude runs as a restricted, firewalled user, and you review and commit from a browser-based editor.

> Gleipnir is an independent project and isn't affiliated with or endorsed by Anthropic. Using Claude Code is subject to Anthropic's terms.

In Norse myth, Gleipnir was the binding that held the giant wolf Fenrir: as thin as a silk ribbon, but impossible to break. Its parts are named from the same story: **Gjöll** is the firewall, **Heimdall** the change checks and **Týr** the managed settings.

## Status

Work in progress. Built so far:

- [x] The VMs, users, Node.js and cloning your project
- [x] The browser editor (code-server)
- [ ] Claude Code with its firewall, managed settings and change checks
- [ ] The dev server
- [ ] Optional PostgreSQL and Playwright
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

1. **Create a deploy key** for the project's repo, without a passphrase, in Gleipnir's `keys/` folder:

   ```bash
   ssh-keygen -t ed25519 -f keys/my-project -C "my-project VM" -N ""
   cat keys/my-project.pub
   ```

   On GitHub, open the project repo's **Settings → Deploy keys**, add the public key, and tick **Allow write access**. The key only works on that one repo.

2. **Create the machine's config.** The file name becomes the VM's name: lowercase letters, digits and dashes.

   ```bash
   cp machines/example.json.example machines/my-project.json
   ```

   Set `repo` (the `git@github.com:…` form), `deploy_key` and your git name and email. If another machine already uses ports 8080 and 5173, pick different `ports`.

3. **Start it:**

   ```bash
   vagrant up my-project
   ```

Your configs in `machines/` and keys in `keys/` are ignored by git, so they never end up in Gleipnir's own repo.

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

Claude Code isn't run from the editor. You'll start it from a terminal on your computer, through `vagrant ssh`, once that step is built.

Safari on older macOS versions can struggle with the editor; a current Chrome or Firefox works best.

## Everyday commands

```bash
vagrant status                # every machine and whether it's running
vagrant up my-project         # start one (a bare `vagrant up` starts none)
vagrant ssh my-project
vagrant halt my-project
vagrant provision my-project  # apply config changes or a Gleipnir update
```

To update Gleipnir itself: `git pull` in this folder, then `vagrant provision <name>` for each running machine.

## Configuration

Each `machines/<name>.json` file supports:

| Field | Default | What it sets |
| --- | --- | --- |
| `repo` | (required) | Git URL cloned into `/srv/project` |
| `deploy_key` | (required for SSH repos) | Path to the repo's deploy key, relative to the Gleipnir folder |
| `git.name` / `git.email` | none | Your identity for commits made in the VM |
| `vm.memory` / `vm.cpus` | 3072 / 2 | VM resources, in MB / cores |
| `ports.editor` / `ports.app` | 8080 / 5173 | Ports on your computer's `localhost`; each machine needs its own |
| `node` | 24 | Node.js major version |
| `extensions` | Svelte, Tailwind, ESLint, Prettier | Editor extensions to install, by ID from the Open VSX registry |

Gleipnir refuses to start if two machines use the same port, and tells you which.

## Important: your work lives in the VM

The project isn't on your computer. Until you push, the only copy of your work is inside its VM, and `vagrant destroy` deletes it. Push often.

## Licence

MIT. See [LICENSE](LICENSE).