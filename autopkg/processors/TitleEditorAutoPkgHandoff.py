#!/usr/bin/env python3
"""AutoPkg processor to run an upstream recipe, then hand off to Title Editor updates."""

import os
import shlex
import shutil
import subprocess

from autopkglib import Processor, ProcessorError


__all__ = ["TitleEditorAutoPkgHandoff"]


class TitleEditorAutoPkgHandoff(Processor):
    description = (
        "Runs an upstream AutoPkg recipe (for example Firefox.munki), then runs "
        "update_title_editor_versions.sh in signal-only or apply-current mode."
    )

    input_variables = {
        "SOURCE_RECIPE": {
            "required": True,
            "description": "Upstream AutoPkg recipe identifier to run (for example Firefox.munki).",
        },
        "TITLE_EDITOR_ITEM": {
            "required": True,
            "description": "Item key for update_title_editor_versions.sh (for example firefox).",
        },
        "HANDOFF_MODE": {
            "required": False,
            "description": "signal-only or apply-current. Defaults to signal-only.",
        },
        "UPDATE_SCRIPT_PATH": {
            "required": False,
            "description": "Path to update_title_editor_versions.sh. Defaults to script in this repository.",
        },
        "AUTOPKG_CMD": {
            "required": False,
            "description": "AutoPkg executable path. Defaults to `autopkg` on PATH.",
        },
        "AUTOPKG_RUN_ARGS": {
            "required": False,
            "description": "Additional args passed to `autopkg run`, as a shell-style string.",
        },
        "TITLE_EDITOR_EXTRA_ARGS": {
            "required": False,
            "description": "Optional extra args for update_title_editor_versions.sh, shell-style string.",
        },
    }

    output_variables = {
        "autopkg_source_recipe": {
            "description": "The upstream recipe run by this processor."
        },
        "title_editor_item": {
            "description": "The item key used for update_title_editor_versions.sh."
        },
        "title_editor_handoff_mode": {
            "description": "Resolved handoff mode."
        },
    }

    def _resolve_autopkg(self):
        configured = self.env.get("AUTOPKG_CMD", "").strip()
        if configured:
            return configured

        discovered = shutil.which("autopkg")
        if discovered:
            return discovered

        raise ProcessorError("Could not locate `autopkg` in PATH. Set AUTOPKG_CMD explicitly.")

    def _resolve_update_script(self):
        configured = self.env.get("UPDATE_SCRIPT_PATH", "").strip()
        if configured:
            path = configured
        else:
            recipe_dir = self.env.get("RECIPE_DIR", "")
            path = os.path.abspath(os.path.join(recipe_dir, "..", "..", "update_title_editor_versions.sh"))

        if not os.path.isfile(path):
            raise ProcessorError(
                "update_title_editor_versions.sh not found at '{}'. Set UPDATE_SCRIPT_PATH.".format(path)
            )

        return path

    def _run(self, cmd, label):
        self.output("Running {}: {}".format(label, " ".join(shlex.quote(x) for x in cmd)))
        try:
            subprocess.check_call(cmd)
        except subprocess.CalledProcessError as err:
            raise ProcessorError("{} failed with exit code {}".format(label, err.returncode))

    def main(self):
        source_recipe = self.env["SOURCE_RECIPE"].strip()
        title_editor_item = self.env["TITLE_EDITOR_ITEM"].strip()

        if not source_recipe:
            raise ProcessorError("SOURCE_RECIPE is required.")
        if not title_editor_item:
            raise ProcessorError("TITLE_EDITOR_ITEM is required.")

        handoff_mode = self.env.get("HANDOFF_MODE", "signal-only").strip().lower()
        if handoff_mode not in ("signal-only", "apply-current"):
            raise ProcessorError("HANDOFF_MODE must be one of: signal-only, apply-current")

        autopkg_cmd = self._resolve_autopkg()
        update_script = self._resolve_update_script()

        autopkg_args = shlex.split(self.env.get("AUTOPKG_RUN_ARGS", ""))
        update_extra_args = shlex.split(self.env.get("TITLE_EDITOR_EXTRA_ARGS", ""))

        run_source_cmd = [autopkg_cmd, "run", source_recipe] + autopkg_args
        self._run(run_source_cmd, "AutoPkg source recipe")

        handoff_cmd = [
            "bash",
            update_script,
            "--item",
            title_editor_item,
            "--current-only",
        ]

        if handoff_mode == "signal-only":
            handoff_cmd.extend(["--no-import", "--no-apply"])

        handoff_cmd.extend(update_extra_args)
        self._run(handoff_cmd, "Title Editor handoff")

        self.env["autopkg_source_recipe"] = source_recipe
        self.env["title_editor_item"] = title_editor_item
        self.env["title_editor_handoff_mode"] = handoff_mode


if __name__ == "__main__":
    PROCESSOR = TitleEditorAutoPkgHandoff()
    PROCESSOR.execute_shell()
