"""Packaging guards: the installed checkout is this repository's tracked tree."""

import json
import re
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


def tracked_files():
    out = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True,
                         check=True, text=True)
    return [line for line in out.stdout.splitlines() if line]


class InstructionFileTests(unittest.TestCase):
    """Marketplace rule (omarchy-plugin-marketplace #6710): agent/workflow
    instruction files must never ride into installed plugin checkouts."""

    BANNED_NAMES = {"AGENTS.md", "CLAUDE.md", "GEMINI.md", ".cursorrules",
                    ".windsurfrules", "copilot-instructions.md"}
    BANNED_PREFIXES = ("AGENTS.", "CLAUDE.", "GEMINI.")
    BANNED_DIRS = (".cursor/",)

    def test_no_agent_instruction_files_tracked(self):
        try:
            files = tracked_files()
        except (subprocess.CalledProcessError, OSError):
            self.skipTest("not a git checkout; the tracked-file check needs git")
        offenders = []
        for path in files:
            name = Path(path).name
            posix = Path(path).as_posix()
            if name in self.BANNED_NAMES or name.startswith(self.BANNED_PREFIXES):
                offenders.append(path)
            if any(posix.startswith(d) or f"/{d}" in posix for d in self.BANNED_DIRS):
                offenders.append(path)
        self.assertEqual(offenders, [])

    def test_agents_md_is_ignored(self):
        gitignore = (ROOT / ".gitignore").read_text()
        self.assertIn("AGENTS.md", gitignore)


class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.manifest = json.loads((ROOT / "manifest.json").read_text())

    def test_required_keys(self):
        for key in ("schemaVersion", "id", "name", "version", "author",
                    "license", "description", "kinds", "entryPoints", "barWidget"):
            self.assertIn(key, self.manifest)

    def test_identity(self):
        self.assertEqual(self.manifest["id"], "kb2uka.port-doctor")
        self.assertEqual(self.manifest["author"], "KB2UKA")
        self.assertEqual(self.manifest["license"], "MIT")
        self.assertEqual(self.manifest["schemaVersion"], 1)
        self.assertIn("bar-widget", self.manifest["kinds"])

    def test_entry_point_exists(self):
        entry = self.manifest["entryPoints"]["barWidget"]
        self.assertTrue((ROOT / entry).is_file(), entry)

    def test_default_section_valid(self):
        section = self.manifest["barWidget"].get("defaultSection")
        self.assertIn(section, ("left", "center", "right"))

    def test_version_matches_package(self):
        from port_doctor import __version__
        self.assertEqual(self.manifest["version"], __version__)

    def test_readme_license_security_present(self):
        self.assertTrue((ROOT / "README.md").is_file())
        self.assertTrue((ROOT / "LICENSE").is_file())
        self.assertTrue((ROOT / "SECURITY.md").is_file())

    def test_preview_present(self):
        self.assertTrue((ROOT / "preview.png").is_file())


class SourceHygieneTests(unittest.TestCase):
    def python_sources(self):
        files = list((ROOT / "port_doctor").glob("*.py"))
        files.append(ROOT / "port-doctor.py")
        return files

    def test_no_shell_execution(self):
        for path in self.python_sources():
            text = path.read_text()
            self.assertNotIn("shell=True", text, path)
            self.assertNotIn("os.system", text, path)
            self.assertNotIn("os.popen", text, path)

    def test_no_extra_dependencies(self):
        allowed_stdlib = {"concurrent", "datetime", "errno", "ipaddress",
                          "json", "os", "pathlib", "select", "socket",
                          "struct", "subprocess", "sys", "time"}
        for path in self.python_sources():
            for match in re.finditer(r"^\s*(?:import|from)\s+([A-Za-z_][\w]*)",
                                     path.read_text(), re.MULTILINE):
                module = match.group(1)
                if module == "port_doctor":
                    continue
                self.assertIn(module, allowed_stdlib, (path, module))

    def test_qml_text_is_plain(self):
        """Every raw Text block renders PlainText (network-derived strings
        must never be parsed as rich text)."""
        lines = (ROOT / "Panel.qml").read_text().splitlines()
        offenders = []
        for index, line in enumerate(lines):
            if re.match(r"^\s*Text \{\s*$", line):
                window = "\n".join(lines[index:index + 4])
                if "textFormat: Text.PlainText" not in window:
                    offenders.append(index + 1)
        self.assertEqual(offenders, [])


if __name__ == "__main__":
    unittest.main()
