"""The machine config's "apps": run with  python3 -m unittest discover tests/unit  from the Gleipnir folder."""
import json
import os
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True  # no __pycache__ beside the scripts

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "..", "scripts", "files", "gleipnir-apps")


def run(config):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as fh:
        json.dump(config, fh)
        path = fh.name
    try:
        out = subprocess.run([sys.executable, "-I", SCRIPT, path], capture_output=True, text=True)
    finally:
        os.remove(path)
    return out.returncode, out.stdout, out.stderr


class AppsTest(unittest.TestCase):
    def test_one_app_by_default(self):
        code, out, _ = run({"repo": "x"})
        self.assertEqual(code, 0)
        self.assertEqual(out, "app\t.\t5173\ttrue\t\n")

    def test_monorepo(self):
        code, out, _ = run({"apps": {"frontend": {"port": 5175}, "backend": {"port": 8002, "path": "api"}}})
        self.assertEqual(code, 0)
        self.assertEqual(out.splitlines(), ["frontend\tfrontend\t5175\ttrue\t", "backend\tapi\t8002\ttrue\t"])

    def refused(self, config, words):
        code, _, err = run(config)
        self.assertNotEqual(code, 0, config)
        self.assertIn(words, err)

    def test_bad_names_and_paths(self):
        self.refused({"apps": {"Front": {"port": 5175}}}, "lowercase")
        self.refused({"apps": {"web": {"port": 5175, "path": "../outside"}}}, "inside the project")
        self.refused({"apps": {"web": {"port": 5175, "path": "/etc"}}}, "inside the project")
        self.refused({"apps": {"web": {"port": 5175, "path": "a/./b"}}}, "inside the project")

    def test_ports(self):
        self.refused({"apps": {"web": {"port": 8080}}}, "used by Gleipnir")
        self.refused({"apps": {"web": {"port": 3129}}}, "used by Gleipnir")
        self.refused({"apps": {"web": {"port": "5175"}}}, "is required")
        self.refused({"apps": {"web": {"port": 80}}}, "is required")
        self.refused({"apps": {"a": {"port": 5175}, "b": {"port": 5175}}}, "same port")

    def test_same_folder(self):
        self.refused({"apps": {"a": {"port": 5175, "path": "x"}, "b": {"port": 5176, "path": "x"}}}, "same folder")

    def test_one_line_commands(self):
        self.refused({"devserver": {"command": "a\nb"}}, "one line")


if __name__ == "__main__":
    unittest.main()