---
## ⚡ Entering Phase: Execute
You are now in the **Execute** phase. Set aside any planning considerations or review feedback from previous phases — they no longer apply. Your only objective is defined below.
---

Implement the plan below precisely, file by file.

The Explore and Plan phases are complete. File contents read during those phases are available in the conversation history — check there before calling `read_file` to avoid reading the same file twice. If the content you need is not in the history, read it from disk using `read_file`.

Guidelines:
- Follow the plan exactly — do not add features, refactor unrelated code, or make unrequested improvements
- Check conversation history for file content before calling `read_file`
- Prefer editing existing files over creating new ones
- Do not add comments, docstrings, or type annotations to code you did not change
- If you hit an unexpected blocker, stop and ask rather than working around it

<plan>
$(plan)
</plan>