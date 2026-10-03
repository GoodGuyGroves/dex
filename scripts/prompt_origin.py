"""Separate the text a human typed from turns Claude Code generated itself.

Claude Code delivers background-task notifications and messages from other
sessions through the same UserPromptSubmit path as a typed prompt, and the
hook input carries no field that says which is which (checked against Claude
Code 2.1.280). A subagent report that quoted `control.sh jump verify` was
therefore recorded as a human phase jump (#35). The envelopes below are the
ones Claude Code wraps around those turns; its own permission classifier
treats the same set as never being user intent.

Imported by adding scripts/ to PYTHONPATH:

    PYTHONPATH="$DEX_DIR/scripts" python3 -c 'import prompt_origin'

Standard library only, to match hooks/guard-handler.py.
"""

import re

# A turn that opens with one of these is system text from start to end: a peer
# message is a preamble line, its envelope and an advisory tail, with nothing
# the human typed.
SYSTEM_TURN_PREFIX = re.compile(
    r"\s*(?:Another Claude session sent a message|A peer session sent a message"
    r"|\[SYSTEM NOTIFICATION - NOT USER INPUT\])"
)

ENVELOPE_TAGS = (
    "task-notification",
    "agent-message",
    "cross-session-message",
    "teammate-message",
)

# The opening tag has to start a line, so a human writing about "<task-notification>
# tags" mid-sentence keeps their prompt. A block runs to the last closing tag of
# its name, because a subagent reporting on notifications can quote one inside
# its result, and without one it runs to the end of the text. Both choices err
# towards reading less as human. The attribute scan stops at a newline so a run
# of unterminated tags cannot make each line rescan the rest of the prompt.
ENVELOPE_BLOCK = re.compile(
    r"^[ \t]*<(" + "|".join(ENVELOPE_TAGS) + r")\b[^>\n]*>(?:.*</\1>|.*)",
    re.MULTILINE | re.DOTALL,
)


def human_prompt_text(text: str) -> str:
    """Return the part of a submitted prompt the human typed.

    Everything outside a system envelope is returned byte for byte, untrimmed,
    so a plain prompt comes back unchanged and its hash still matches.
    """
    if SYSTEM_TURN_PREFIX.match(text):
        return ""
    return ENVELOPE_BLOCK.sub("", text)
