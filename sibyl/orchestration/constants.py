"""Shared orchestration constants."""

RUNTIME_GITIGNORE_LINES = (
    "*.pyc",
    "__pycache__/",
    ".DS_Store",
    ".venv/",
    "OPENCODE.md",
    ".opencode/agents",
    ".opencode/skills",
    ".sibyl/system.json",
)

PAPER_SECTIONS = [
    ("intro", "Introduction"),
    ("related_work", "Related Work"),
    ("method", "Method"),
    ("experiments", "Experiments"),
    ("discussion", "Discussion"),
    ("conclusion", "Conclusion"),
]

CHECKPOINT_DIRS = {
    "idea_debate": "idea",
    "result_debate": "idea/result_debate",
    "writing_sections": "writing/sections",
    # writing_critique checkpoints are now managed inside writing_integrate
    "writing_integrate": "writing/critique",
}

# Backward compat alias so existing checkpoint references still resolve.
CHECKPOINT_DIRS_COMPAT = {"writing_critique": "writing/critique"}

PIPELINE_STAGES = [
    "init",
    "literature_search",
    "idea_debate",
    "planning",
    "pilot_experiments",
    "idea_validation_decision",
    "experiment_cycle",
    "result_debate",
    "experiment_decision",
    "writing_outline",
    "writing_sections",
    # writing_critique merged into writing_integrate (critique + editor in one team)
    "writing_integrate",
    "writing_final_review",
    "writing_latex",
    "review",
    "reflection",
    "quality_gate",
    "done",
]

# Stages that should NOT trigger Lark sync (intermediate writing stages, init, etc.)
SYNC_SKIP_STAGES = {
    "writing_outline",
    "writing_sections",
    "writing_integrate",
    "writing_final_review",
    "init",
    "quality_gate",
    "done",
    "lark_sync",
}
