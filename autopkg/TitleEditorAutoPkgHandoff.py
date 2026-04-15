#!/usr/bin/env python3
"""AutoPkg processor to hand off an already-run recipe to Title Editor updates."""

import os
import shlex
import subprocess

from autopkglib import Processor, ProcessorError


__all__ = ["TitleEditorAutoPkgHandoff"]


class TitleEditorAutoPkgHandoff(Processor):
    description = (
        "Runs update_title_editor_versions.sh after the main AutoPkg recipe has "
        "already completed, typically via autopkg run --post."
    )

    input_variables = {
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
        "TITLE_EDITOR_EXTRA_ARGS": {
            "required": False,
            "description": "Optional extra args for update_title_editor_versions.sh, shell-style string.",
        },
    }

    output_variables = {
        "title_editor_item": {
            "description": "The item key used for update_title_editor_versions.sh."
        },
        "title_editor_handoff_mode": {
            "description": "Resolved handoff mode."
        },
        "title_editor_update_script": {
            "description": "Resolved path to update_title_editor_versions.sh."
        },
    }

    def _resolve_update_script(self):
        configured = self.env.get("UPDATE_SCRIPT_PATH", "").strip()
        if configured:
            path = configured
        else:
            processor_dir = os.path.dirname(os.path.abspath(__file__))
            path = os.path.abspath(os.path.join(processor_dir, "..", "update_title_editor_versions.sh"))

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
        title_editor_item = self.env["TITLE_EDITOR_ITEM"].strip()

        if not title_editor_item:
            raise ProcessorError("TITLE_EDITOR_ITEM is required.")

        handoff_mode = self.env.get("HANDOFF_MODE", "signal-only").strip().lower()
        if handoff_mode not in ("signal-only", "apply-current"):
            raise ProcessorError("HANDOFF_MODE must be one of: signal-only, apply-current")

        update_script = self._resolve_update_script()
        update_extra_args = shlex.split(self.env.get("TITLE_EDITOR_EXTRA_ARGS", ""))

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

        self.env["title_editor_item"] = title_editor_item
        self.env["title_editor_handoff_mode"] = handoff_mode
        self.env["title_editor_update_script"] = update_script


if __name__ == "__main__":
    PROCESSOR = TitleEditorAutoPkgHandoff()
    PROCESSOR.execute_shell()