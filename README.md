# Gleipnir

A Vagrant VM for running Claude Code safely: the project lives inside the VM, Claude runs as a restricted, firewalled user, and you review and commit from a browser-based editor.

> Gleipnir is an independent project and isn't affiliated with or endorsed by Anthropic. Using Claude Code is subject to Anthropic's terms.

In Norse myth, Gleipnir was the binding that held the giant wolf Fenrir: as thin as a silk ribbon, but impossible to break. Its parts are named from the same story: **Gjöll** is the firewall, **Heimdall** the change checks and **Týr** the managed settings.

## Status

Work in progress. Built so far:

- [x] The VM, users, Node.js and cloning your project
- [ ] The browser editor (code-server)
- [ ] Claude Code with its firewall, managed settings and change checks
- [ ] The dev server
- [ ] Optional PostgreSQL and Playwright
- [ ] Running on a VPS

## How it works

- **One VM per project.** Your repo is cloned onto the VM's own disk, not shared from your computer, which keeps it fast and keeps project code off your machine.
- **Two working users, neither with `sudo`:** `dev` for your daily work (the editor, git, the dev server) and `claude` for Claude Code. They share the project through a `project` group.
- **Your computer only runs a browser.** The editor and the app are reached on your own `localhost`, through forwarded ports.
- **One entry point:** `install.sh` does all the setup. Vagrant runs it inside the VM; on a VPS you run it yourself.

## Requirements

- [Vagrant](https://developer.hashicorp.com/vagrant) 2.4 or later
- [VirtualBox](https://www.virtualbox.org/)
- A Claude Pro, Max, Team or Enterprise plan, or an Anthropic API key
- About 4 GB of free memory per VM

## Getting started

1. **Create a deploy key for your project's repo**, without a passphrase:

   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/myproject-deploy -C "myproject VM" -N ""
   cat ~/.ssh/myproject-deploy.pub
   ```

   On GitHub, open the repo's **Settings → Deploy keys**, add the public key, and tick **Allow write access**. The key only works on that one repo.

2. **Create your config:**

   ```bash
   cp config.json.example config.json
   ```

   Set `name`, `repo` (the `git@github.com:…` form) and `deploy_key`, plus your git name and email.

3. **Start it:**

   ```bash
   vagrant up
   ```

### Checking it worked

After `vagrant ssh`:

```bash
id dev; id claude                       # both in group "project", neither in sudo
node -v                                 # the version from config.json
ls -la /srv/project                     # owned by dev, group project
sudo -u dev git -C /srv/project status  # a clean working tree
```

## Configuration

| Field | Default | What it sets |
| --- | --- | --- |
| `name` | (required) | VM name |
| `repo` | (required) | Git URL cloned into `/srv/project` |
| `deploy_key` | (required for SSH repos) | Path to the repo's deploy key on your computer |
| `git.name` / `git.email` | none | Your identity for commits made in the VM |
| `vm.memory` / `vm.cpus` | 3072 / 2 | VM resources, in MB / cores |
| `ports.editor` / `ports.app` | 8080 / 5173 | Ports on your computer's `localhost` |
| `node` | 24 | Node.js major version |

Running more than one VM? Give each its own `ports`, since two VMs can't share a port on your computer.

## Important: your work lives in the VM

The project isn't on your computer. Until you push, the only copy of your work is inside the VM, and `vagrant destroy` deletes it. Push often.

## Licence

MIT. See [LICENSE](LICENSE).
