# OpenScientist Platform Guide

OpenScientist is a research and engineering workspace for running AI agents
against real project folders, research corpora, notes, skills, and sandboxed
tools. It is useful when a task benefits from more than one step of reasoning:
collecting sources, reading files, building a plan, delegating work, executing
code, preserving notes, and steering a run as new evidence arrives.

The harness is strongest at tasks that need context and iteration. It can index
papers, inspect code, write or update notes, call specialized research tools,
use project-specific skills, and coordinate longer runs across multiple agent
providers. It is less suited to one-shot answers that do not need external
state, file access, or tool execution.

## Research Papers And Indexing

OpenScientist can aggregate research papers from literature sources and index
them into a searchable workspace. Agents can search by topic, retrieve metadata,
read abstracts, index full text when available, and cite or summarize relevant
papers in a note or report.

Indexed documents become part of the workspace context. This lets agents move
from broad discovery to focused reading without repeatedly asking the user to
upload the same material. A good workflow is to search broadly, index the most
relevant papers, then ask the agent to compare methods, extract assumptions, or
prepare a structured literature summary.

## Skills Marketplace

Skills are packaged instructions, scripts, and reference material that teach an
agent how to perform a specialized workflow. A skill can describe when it should
be used, define command-line helpers, include templates, and document expected
inputs and outputs.

The marketplace makes skills discoverable and reusable. Agents should inspect a
skill before relying on it, follow its local instructions, and prefer the skill's
provided scripts over reimplementing the same workflow. Skills are especially
useful for repeatable lab operations, data processing conventions, writing
formats, sandbox setup, and domain-specific analysis.

## Sandboxing

Sandboxing gives agents an isolated execution environment for commands that
need extra packages, reproducibility, or separation from the host workspace. A
sandbox can provide a known operating system image, language tooling, and mounted
project files while keeping the workflow explicit.

Use a sandbox when code has unfamiliar dependencies, when a task needs a clean
environment, or when a workflow should be reproducible by another agent. Keep
inputs and outputs clear: put source files in the mounted workspace, write
results to named paths, and record commands that mattered.

## Cloud Runs On The User's Machine

OpenScientist can coordinate cloud-managed runs that execute on the user's own
machine. The platform can supervise the run, route messages, and expose progress
while the actual files, worktrees, and local commands remain on the machine that
owns the project.

This model is useful for long-running research or coding jobs because it keeps
the agent close to the project environment. The user can continue to steer the
run, inspect artifacts, stop work, or launch follow-up workers while retaining
local control over data and execution.

## Database-Backed Research Data

Some OpenScientist tools use managed databases behind the scenes for fast access
to research metadata, Hugging Face information, indexed documents, and corpus
records. Agents can query these resources through the platform tools instead of
scraping ad hoc pages or maintaining their own cache.

For research work, this means agents can combine literature search, paper
metadata, model and dataset discovery, and workspace notes in a single flow. For
engineering work, it means results can be reused across sessions when they have
been indexed or saved intentionally.

## Deep Runs Across Providers

Deep runs coordinate longer work across providers such as Codex, Claude Code,
and Gecko. The orchestrator plans the work, starts workers, exchanges mail, and
tracks progress. Workers can take bounded subtasks, inspect files, run commands,
and report back with findings or patches.

Use deep runs when the task is too broad for a single linear pass: large
codebase changes, literature reviews, benchmark sweeps, multi-file debugging, or
parallel investigation. The best prompts define the desired outcome, constraints,
success criteria, and any files or resources that are in scope.

## Worktrees And Steering

Worktree support lets agents operate in isolated copies of a repository while
preserving the user's main checkout. This is useful for parallel workers, risky
experiments, and implementation branches that should not disturb current work.

Steering is the process of guiding an active run. The user can send new
instructions, correct assumptions, narrow scope, request status, or stop work.
Good steering messages are concrete: name the current concern, point to the
artifact or file that matters, and say what should change.

## Notes And Formatting

Notes are durable workspace artifacts for research logs, plans, summaries,
citations, and decisions. Agents should use notes when information needs to
survive beyond the chat transcript or when a structured report will be edited
over time.

Keep notes readable. Prefer Markdown headings, short paragraphs, tables for
comparisons, and explicit source references. Separate facts from interpretation,
mark open questions, and include enough context that another agent or user can
resume the work later without rebuilding the entire trail.

## Practical Workflow

1. Start with the goal, constraints, and source material.
2. Search or index the documents and files that matter.
3. Use skills when a documented workflow exists.
4. Use sandboxes for reproducible or dependency-heavy execution.
5. Use deep runs for parallel work or broad investigations.
6. Save durable findings in notes or generated artifacts.
7. Steer the run with concrete corrections as new evidence appears.
