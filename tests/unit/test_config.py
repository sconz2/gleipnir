"""The whole-config check: run with  python3 -m unittest discover tests/unit  from the Gleipnir folder."""
import glob
import importlib.machinery
import importlib.util
import json
import os
import sys
import unittest

sys.dont_write_bytecode = True  # no __pycache__ beside the scripts

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..", "..")
SCRIPT = os.path.join(ROOT, "scripts", "files", "gleipnir-config")

loader = importlib.machinery.SourceFileLoader("gleipnir_config", SCRIPT)
spec = importlib.util.spec_from_loader("gleipnir_config", loader)
gleipnir_config = importlib.util.module_from_spec(spec)
loader.exec_module(gleipnir_config)

BASE = {"repo": "git@github.com:you/project.git"}


def problems(**settings):
    return gleipnir_config.Checker(dict(BASE, **settings)).check()


class ConfigTest(unittest.TestCase):
    def assertProblem(self, found, words):
        self.assertTrue(any(words in p for p in found), f"no problem mentioning {words!r} in {found}")

    def test_examples_pass(self):
        examples = glob.glob(os.path.join(ROOT, "machines", "*.json.example"))
        self.assertTrue(examples)
        for path in examples:
            with open(path) as fh:
                self.assertEqual(gleipnir_config.Checker(json.load(fh)).check(), [], path)

    def test_minimal_config_passes(self):
        self.assertEqual(problems(), [])

    def test_repo_is_required(self):
        self.assertProblem(gleipnir_config.Checker({}).check(), "repo: is required")

    def test_typos_are_caught_with_a_suggestion(self):
        found = problems(vm={"cpu": 2}, claude={"allowed_domain": []})
        self.assertProblem(found, 'vm.cpu: isn\'t a setting Gleipnir knows (did you mean "cpus"?)')
        self.assertProblem(found, 'did you mean "allowed_domains"')

    def test_comments_are_allowed(self):
        self.assertEqual(problems(_note="anything", vm={"_why": "x", "memory": 4096}), [])
        self.assertEqual(problems(apps={"_note": "x", "web": {"port": 5175}}), [])
        self.assertEqual(problems(ports={"_note": "x"}), [])

    def test_older_configs_still_pass(self):
        self.assertEqual(problems(name="my-project"), [])

    def test_types_and_ranges(self):
        self.assertProblem(problems(vm={"memory": "4096"}), "vm.memory: must be a whole number")
        self.assertProblem(problems(vm={"memory": 512}), "vm.memory: must be from 1024")
        self.assertProblem(problems(vm={"cpus": True}), "vm.cpus")
        self.assertProblem(problems(ports={"editor": 70000}), "ports.editor")
        self.assertProblem(problems(php={"enabled": "true"}), "php.enabled: must be true or false")
        self.assertProblem(problems(php={"version": "8"}), 'php.version: must be a version like "8.4"')
        self.assertEqual(problems(php={"version": 8.4}), [])
        self.assertProblem(problems(node="abc"), "node")
        self.assertEqual(problems(node="24"), [])

    def test_postgres(self):
        self.assertProblem(problems(postgres={"enabled": True}), "postgres.password: is required")
        self.assertProblem(problems(postgres={"user": "postgres"}), "postgres.user")
        self.assertEqual(problems(postgres={"databases": ["my-project", "My_DB2"]}), [])
        self.assertProblem(problems(postgres={"databases": ["-x"]}), "postgres.databases")
        self.assertProblem(problems(postgres={"databases": ["my db"]}), "postgres.databases")
        self.assertProblem(problems(postgres={"databases": ["template1"]}), "postgres.databases")
        self.assertEqual(problems(postgres={"version": "17"}), [])
        self.assertProblem(problems(postgres={"version": 14}), "postgres.version: must be from 15")
        self.assertProblem(problems(postgres={"createdb": "no"}), "postgres.createdb")
        self.assertProblem(problems(postgres={"password": "a\nb"}), "one line")

    def test_network_and_sites(self):
        self.assertProblem(problems(claude={"network": "closed"}), "claude.network")
        self.assertProblem(problems(runner={"allowed_domains": ["1.2.3.4"]}), "isn't a site name")
        self.assertEqual(problems(claude={"allowed_domains": ["docs.example.com", ".example.org", "*.example.net"]}), [])

    def test_extensions(self):
        self.assertEqual(problems(extensions=["esbenp.prettier-vscode", "svelte.svelte-vscode@109.5.2"]), [])
        self.assertProblem(problems(extensions=["prettier"]), "isn't an extension ID")

    def test_editor(self):
        self.assertEqual(problems(editor={"auth": "none"}), [])
        self.assertProblem(problems(editor={"auth": "token"}), "editor.auth")

    def test_apps(self):
        self.assertProblem(problems(apps={"web": {"port": 5175, "pth": "x"}}), 'did you mean "path"')
        self.assertProblem(problems(apps={"web": {"port": 8080}}), "used by Gleipnir")
        self.assertProblem(problems(apps={"web": {"port": 5175, "path": "../x"}}), "inside the project")
        self.assertEqual(problems(apps={"web": {"port": 5175, "devserver": {"command": "npm start"}}}), [])

    def test_every_problem_is_listed(self):
        self.assertGreaterEqual(len(problems(vm={"memory": 1}, node="x", editor={"auth": "x"})), 3)


if __name__ == "__main__":
    unittest.main()