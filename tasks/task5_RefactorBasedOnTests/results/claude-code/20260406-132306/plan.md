# Refactor export_flows.py into smaller modules

## Context
`export_flows.py` is 1,430 lines covering constants, utilities, I/O, response parsing, flow processing, usage extraction, cost calculation, source attribution, and summarization — all in one flat file. The goal is to split it into cohesive private sub-modules while keeping the public interface fully stable: every name importable from `export_flows` must remain importable from `export_flows`.

The test file (`test_export_flows.py`) imports all names directly from `export_flows` and also uses:
```python
@patch("export_flows.FlowWriter")
@patch("export_flows.FlowReader")
@patch("export_flows.glob.glob")
```
These patch targets require that `FlowWriter`, `FlowReader`, and the `glob` module remain in `export_flows`'s own namespace.

## Approach: Facade with private sub-modules

`export_flows.py` stays as a module file (not converted to a package). New private modules are named `_ef_*.py` (underscore prefix signals internal). `export_flows.py` imports from them explicitly and re-exports every name via `from _ef_X import Y` statements, keeping all public symbols accessible at `export_flows.Y`.

**Functions kept in `export_flows.py`** (not extracted) due to patch-target constraints:
- `redact_flow_files` — tests patch `export_flows.FlowWriter`, `export_flows.FlowReader`, `export_flows.glob.glob`
- `export_flows` (the function) — tests patch `export_flows.FlowReader`, `export_flows.glob.glob`
- `main()` — orchestrator entry point

## Module breakdown

| New file | Contents | Lines (approx) |
|---|---|---|
| `_ef_constants.py` | `SYSTEM_PROMPT_INDEX`, `MODEL_PRICING`, `_SORTED_PREFIXES`, `_REDACTED_HEADERS`, `READ_TOOLS`, `WRITE_TOOLS`, `_PROJECT_ROOT`, `AGENT_COLORS` | ~35 |
| `_ef_utils.py` | `count_whitespace_stats`, `parse_request_body`, `get_canonical_model`, `get_pricing`, `sanitize_path`, `format_headers`, `_resolve_read_file_name` | ~110 |
| `_ef_io.py` | `write_request`, `write_response` | ~45 |
| `_ef_response.py` | `extract_stop_reason`, `_format_tool_params`, `parse_response_content`, `export_parsed_response`, `export_parsed_responses`, `categorize_output_sources` | ~245 |
| `_ef_flow.py` | `_system_prompt_hash` | ~15 |
| `_ef_usage.py` | `extract_usage`, `extract_prompts` | ~125 |
| `_ef_attribution.py` | `_get_file_path`, `extract_read_file_whitespace`, `categorize_input_sources`, `attribute_tokens`, `extract_file_ops`, `extract_source_attribution` | ~290 |
| `_ef_costs.py` | `calculate_costs` | ~65 |
| `_ef_summary.py` | `_aggregate_by_source`, `_round_by_source`, `_agent_color`, `summarize_usage` | ~295 |
| `export_flows.py` | re-exports + `redact_flow_files` + `export_flows()` + `main()` | ~250 |

## Import dependency graph (no cycles)

```
_ef_constants  (stdlib only)
_ef_utils      → _ef_constants
_ef_io         → _ef_utils
_ef_response   → _ef_utils (_resolve_read_file_name)
_ef_flow       → _ef_constants, _ef_utils, _ef_io, _ef_response
_ef_usage      → _ef_utils
_ef_attribution → _ef_constants, _ef_utils, _ef_response
_ef_costs      → _ef_utils
_ef_summary    → _ef_constants
export_flows   → all of the above; keeps FlowReader/FlowWriter/glob imports
```

Note: `_resolve_read_file_name` is shared by `_ef_response.py` (used in `categorize_output_sources`) and `_ef_attribution.py` (used in `categorize_input_sources`, `extract_file_ops`). Placing it in `_ef_utils.py` breaks the cycle.

## Step-by-step execution

Each step ends with `python -m pytest test_export_flows.py` before proceeding.

1. **Extract `_ef_constants.py`** — create file with all constants; replace definitions in `export_flows.py` with `from _ef_constants import ...` — run tests
2. **Extract `_ef_utils.py`** — includes `_resolve_read_file_name` (moved here from attribution area); replace in `export_flows.py` — run tests
3. **Extract `_ef_io.py`** — `write_request`, `write_response`; replace in `export_flows.py` — run tests
4. **Extract `_ef_response.py`** — SSE/response parsing functions; replace in `export_flows.py` — run tests
5. **Extract `_ef_flow.py`** — `_system_prompt_hash` only; replace in `export_flows.py` — run tests
6. **Extract `_ef_usage.py`** — `extract_usage`, `extract_prompts`; replace in `export_flows.py` — run tests
7. **Extract `_ef_attribution.py`** — full attribution pipeline; replace in `export_flows.py` — run tests
8. **Extract `_ef_costs.py`** — `calculate_costs`; replace in `export_flows.py` — run tests
9. **Extract `_ef_summary.py`** — summarization helpers + `summarize_usage`; replace in `export_flows.py` — run tests
10. **Final cleanup** — ensure `export_flows.py` retains top-level imports (`import glob`, `from mitmproxy.io import FlowReader, FlowWriter`) needed by patch targets and the two remaining functions

## Critical files

- `/workspace/export_flows.py` — modified at each step (re-exports added, bodies removed)
- `/workspace/test_export_flows.py` — **read-only**; must pass after every step
- New files: `_ef_constants.py`, `_ef_utils.py`, `_ef_io.py`, `_ef_response.py`, `_ef_flow.py`, `_ef_usage.py`, `_ef_attribution.py`, `_ef_costs.py`, `_ef_summary.py`

## Verification

After every step: `python -m pytest test_export_flows.py -v`

Final check: `python -c "import export_flows; export_flows.main.__doc__"` to confirm `main()` is accessible and the module loads cleanly.
