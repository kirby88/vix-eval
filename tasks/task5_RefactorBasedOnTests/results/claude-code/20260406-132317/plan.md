# Refactor export_flows.py — Implementation Plan

## Context

`export_flows.py` is a 1430-line monolith with 6 logical concerns mixed together: pricing/model data, HTTP flow I/O helpers, SSE response parsing, tool attribution, usage/cost tracking, and the mitmproxy-specific export functions. The goal is to split it into focused modules while preserving all public API and test compatibility.

**Key constraint:** `test_export_flows.py` does `import export_flows as ef` and accesses every function (including private `_` ones) via `ef.name`. Also, tests for `redact_flow_files` and `export_flows` use:
- `@patch("export_flows.glob.glob")`
- `@patch("export_flows.FlowReader")`
- `@patch("export_flows.FlowWriter")`

This means `redact_flow_files` and `export_flows` (the function) **must stay in `export_flows.py`** — moving them would break the patch targets.

---

## Target Module Structure

| File | Lines (est.) | Contents |
|---|---|---|
| `ef_pricing.py` | ~35 | `SYSTEM_PROMPT_INDEX`, `MODEL_PRICING`, `_SORTED_PREFIXES`, `get_canonical_model`, `get_pricing` |
| `ef_flow_io.py` | ~110 | `_REDACTED_HEADERS`, `sanitize_path`, `format_headers`, `write_request`, `write_response`, `extract_stop_reason`, `_system_prompt_hash` |
| `ef_response.py` | ~200 | `_format_tool_params`, `parse_response_content`, `export_parsed_response`, `export_parsed_responses`, `categorize_output_sources` |
| `ef_tools.py` | ~290 | `READ_TOOLS`, `WRITE_TOOLS`, `_PROJECT_ROOT`, `count_whitespace_stats`, `_resolve_read_file_name`, `_get_file_path`, `extract_read_file_whitespace`, `categorize_input_sources`, `attribute_tokens`, `extract_file_ops`, `extract_source_attribution` |
| `ef_usage.py` | ~260 | `AGENT_COLORS`, `parse_request_body`, `extract_usage`, `extract_prompts`, `calculate_costs`, `_aggregate_by_source`, `_round_by_source`, `_agent_color`, `summarize_usage` |
| `export_flows.py` | ~200 | Re-export facade + retained: `redact_flow_files`, `export_flows` fn, `main()` |

**Total: ~1095 lines across 6 files (down from 1430 in one file)**

---

## Circular Import — How to Break It

`ef_response.py` needs `_resolve_read_file_name` (lives in `ef_tools.py`).
`ef_tools.py` (specifically `extract_file_ops`) needs `parse_response_content` (lives in `ef_response.py`).

**Solution:** Use a **late (deferred) import** inside `extract_file_ops` in `ef_tools.py`:
```python
def extract_file_ops(body, response_path):
    from ef_response import parse_response_content  # late import to break cycle
    ...
```
`ef_response.py` does a normal top-level `from ef_tools import _resolve_read_file_name`.

---

## Re-Export Facade Pattern

After all modules are extracted, `export_flows.py` will re-export every symbol via explicit imports so that `ef.name` continues to work for all test accesses:

```python
from ef_pricing import SYSTEM_PROMPT_INDEX, MODEL_PRICING, _SORTED_PREFIXES, get_canonical_model, get_pricing
from ef_flow_io import _REDACTED_HEADERS, sanitize_path, format_headers, write_request, write_response, extract_stop_reason, _system_prompt_hash
from ef_response import _format_tool_params, parse_response_content, export_parsed_response, export_parsed_responses, categorize_output_sources
from ef_tools import READ_TOOLS, WRITE_TOOLS, _PROJECT_ROOT, count_whitespace_stats, _resolve_read_file_name, _get_file_path, extract_read_file_whitespace, categorize_input_sources, attribute_tokens, extract_file_ops, extract_source_attribution
from ef_usage import AGENT_COLORS, parse_request_body, extract_usage, extract_prompts, calculate_costs, _aggregate_by_source, _round_by_source, _agent_color, summarize_usage
# Plus: mitmproxy imports remain here for test patch targets
# Plus: redact_flow_files and export_flows (function) defined here
# Plus: main() defined here
```

---

## Incremental Steps (test after each)

Each step: move code to a new file, add `from new_module import ...` in `export_flows.py`, run `pytest test_export_flows.py`.

### Step 1 — Extract `ef_pricing.py`
Move: `SYSTEM_PROMPT_INDEX`, `MODEL_PRICING`, `_SORTED_PREFIXES`, `get_canonical_model`, `get_pricing`

`export_flows.py` change: replace definitions with `from ef_pricing import ...`

Risk: **minimal** — pure data, no deps, no I/O.

### Step 2 — Extract `ef_flow_io.py`
Move: `_REDACTED_HEADERS`, `sanitize_path`, `format_headers`, `write_request`, `write_response`, `extract_stop_reason`, `_system_prompt_hash`

`ef_flow_io.py` imports: `hashlib`, `json`, `os`, `re`; `from ef_pricing import SYSTEM_PROMPT_INDEX`

`export_flows.py` change: replace definitions with `from ef_flow_io import ...`; **keep** `mitmproxy` imports, `redact_flow_files`, and `export_flows` (function) in place — they use `_REDACTED_HEADERS` and the mitmproxy classes directly and are patch targets.

Risk: **low** — helpers only, no mitmproxy in the new file.

### Step 3 — Extract `ef_usage.py`
Move: `AGENT_COLORS`, `parse_request_body`, `extract_usage`, `extract_prompts`, `calculate_costs`, `_aggregate_by_source`, `_round_by_source`, `_agent_color`, `summarize_usage`

`ef_usage.py` imports: `hashlib`, `json`, `os`; `from ef_pricing import get_canonical_model, get_pricing`

`export_flows.py` change: replace definitions with `from ef_usage import ...`

Risk: **medium** — `summarize_usage` is 200 lines but self-contained; all cross-module calls are to `ef_pricing` only.

### Step 4 — Extract `ef_response.py`
Move: `_format_tool_params`, `parse_response_content`, `export_parsed_response`, `export_parsed_responses`, `categorize_output_sources`

`ef_response.py` imports: `json`, `os`; `from ef_tools import _resolve_read_file_name`

BUT `ef_tools.py` doesn't exist yet — use a **temporary shim**: at this step, `_resolve_read_file_name` still lives in `export_flows.py`, so `ef_response.py` temporarily imports `from export_flows import _resolve_read_file_name`. This will be updated in Step 5.

`export_flows.py` change: replace definitions with `from ef_response import ...`

Risk: **low** — all pure parsing functions.

### Step 5 — Extract `ef_tools.py`
Move: `READ_TOOLS`, `WRITE_TOOLS`, `_PROJECT_ROOT`, `count_whitespace_stats`, `_resolve_read_file_name`, `_get_file_path`, `extract_read_file_whitespace`, `categorize_input_sources`, `attribute_tokens`, `extract_file_ops`, `extract_source_attribution`

`ef_tools.py` imports:
- `json`, `os`, `re`
- `from ef_pricing import get_pricing`
- `from ef_usage import parse_request_body`
- Inside `extract_file_ops` function body: `from ef_response import parse_response_content` (late import)

Also update `ef_response.py`: change `from export_flows import _resolve_read_file_name` → `from ef_tools import _resolve_read_file_name`

`export_flows.py` change: replace definitions with `from ef_tools import ...`; also update `export_flows` (function) to use `_system_prompt_hash` from `ef_flow_io` (already imported) and `write_request`/`write_response`/`extract_stop_reason` from `ef_flow_io` (already re-exported).

Risk: **medium** — largest extraction; the late import in `extract_file_ops` must be verified. `_PROJECT_ROOT` uses `__file__` which stays correct (same directory).

### Step 6 — Finalize `export_flows.py`
Clean up the facade: verify all names are re-exported, remove any leftover duplicate definitions, confirm `main()` is intact.

Run full test suite one final time.

---

## Critical Files

- `/workspace/export_flows.py` — main file being refactored
- `/workspace/test_export_flows.py` — **do not modify**
- `/workspace/ef_pricing.py` — to be created
- `/workspace/ef_flow_io.py` — to be created
- `/workspace/ef_response.py` — to be created
- `/workspace/ef_tools.py` — to be created
- `/workspace/ef_usage.py` — to be created

---

## Verification

After each step: `pytest test_export_flows.py -v` must pass all 60+ tests with 0 failures.

Final check: `python -c "import export_flows as ef; print(ef.main.__module__)"` should print `export_flows`.
