# Refactor export_flows.py

## Context

`export_flows.py` is a 1,430-line monolithic file that processes mitmproxy HTTP flows. It has two structural problems:
1. **Constants scattered mid-file**: `READ_TOOLS`, `WRITE_TOOLS` (line 899), `_PROJECT_ROOT` (line 903), and `AGENT_COLORS` (line 1190) are defined far from the other constants at the top.
2. **No logical grouping**: Functions are ordered roughly by pipeline execution order, not by category, making navigation hard.

**Why no module split**: The test file patches `export_flows.glob.glob`, `export_flows.FlowReader`, and `export_flows.FlowWriter`. If those functions move to submodules, the patches would need to change too. In-file reorganization achieves the maintainability goal without any test churn.

## Critical file
- `/workspace/export_flows.py` (1,430 lines — the only file to modify)
- `/workspace/test_export_flows.py` (tests to run after each step, never modified)

## Refactoring steps

### Step 1 — Add module docstring + section skeleton
Replace the existing one-line docstring with a multi-line docstring that describes the module's purpose and lists its sections. Add section-header comments as empty dividers so the overall shape is visible before functions move.

Run tests: `python -m pytest test_export_flows.py -q`

### Step 2 — Move scattered constants to the top
Move these four definitions up to sit immediately after `_SORTED_PREFIXES` (~line 33):
- `READ_TOOLS` (currently line 899)
- `WRITE_TOOLS` (currently line 900)
- `_PROJECT_ROOT` (currently line 903)
- `AGENT_COLORS` (currently line 1190)

The functions that depend on them (`_get_file_path`, `extract_file_ops`, `_agent_color`) are resolved at call-time, so moving the constants earlier is safe.

Run tests: `python -m pytest test_export_flows.py -q`

### Step 3 — Reorganize functions into logical sections
Reorder functions so they fall under their section headers. Each section gets a banner comment: `# ── Section Name ────────────────────────────────────────────`.

Target grouping:

| Section | Functions |
|---|---|
| **Constants** | SYSTEM_PROMPT_INDEX, MODEL_PRICING, _SORTED_PREFIXES, _REDACTED_HEADERS, READ_TOOLS, WRITE_TOOLS, _PROJECT_ROOT, AGENT_COLORS |
| **String & Path Utilities** | count_whitespace_stats, sanitize_path, format_headers, _format_tool_params, _resolve_read_file_name, _agent_color |
| **Model & Pricing** | get_canonical_model, get_pricing |
| **HTTP I/O** | parse_request_body, write_request, write_response, redact_flow_files |
| **Response Parsing** | extract_stop_reason, parse_response_content, export_parsed_response, export_parsed_responses |
| **Flow Export** | _system_prompt_hash, export_flows, extract_usage, extract_prompts |
| **Token Attribution & Source Analysis** | _get_file_path, categorize_input_sources, categorize_output_sources, extract_read_file_whitespace, attribute_tokens, extract_file_ops, extract_source_attribution |
| **Cost Calculation** | calculate_costs |
| **Usage Summarization** | _aggregate_by_source, _round_by_source, summarize_usage |
| **Entry Point** | main(), `if __name__ == "__main__"` |

Python resolves function references at call-time, so reordering definitions is safe as long as no module-level code calls a function defined later. The only module-level expressions are constant derivations (`_SORTED_PREFIXES = sorted(...)`) — these will remain in order.

Run tests: `python -m pytest test_export_flows.py -q`

## Verification
After all steps, run the full test suite and confirm all tests pass:
```
cd /workspace && python -m pytest test_export_flows.py -v
```

No test should fail. The external API (all public function signatures, `main()`, constants, module-level names) is unchanged.
