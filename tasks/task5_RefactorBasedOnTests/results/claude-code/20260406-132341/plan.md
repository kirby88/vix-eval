# Refactor `export_flows.py` into Smaller Modules

## Context

`export_flows.py` is 1,430 lines containing four distinct concerns mixed together:
model config, SSE/response parsing, token attribution analysis, and main orchestration. Splitting it improves navigability and maintainability without changing any external behavior.

The test suite (`test_export_flows.py`) does `import export_flows as ef` and calls every public **and** private function via `ef.<name>()`. All 30+ names (including `ef._resolve_read_file_name`, `ef._format_tool_params`, `ef._agent_color`, etc.) must remain accessible from `export_flows` after the split. This is achieved by adding explicit re-export imports to `export_flows.py`.

---

## Modules to Create

### `model_config.py` (~50 lines)
Model pricing tables, agent colors, canonical model lookups.

Symbols: `SYSTEM_PROMPT_INDEX`, `MODEL_PRICING`, `_SORTED_PREFIXES`, `AGENT_COLORS`, `get_canonical_model`, `get_pricing`, `_agent_color`

Imports needed: `hashlib` (for `_agent_color`)

Note: `_agent_color` has an inline `import hashlib` in the original — remove it and use the top-level import instead.

### `sse_parsing.py` (~230 lines)
SSE stream parsing, response content extraction, output categorization.

Symbols: `extract_stop_reason`, `_resolve_read_file_name`, `_format_tool_params`, `parse_response_content`, `export_parsed_response`, `export_parsed_responses`, `categorize_output_sources`

Imports needed: `json`, `os`

### `token_analysis.py` (~290 lines)
Whitespace stats, input/output source categorization, token attribution, file operation tracking.

Symbols: `count_whitespace_stats`, `READ_TOOLS`, `WRITE_TOOLS`, `_PROJECT_ROOT`, `_get_file_path`, `extract_read_file_whitespace`, `categorize_input_sources`, `extract_file_ops`, `attribute_tokens`, `_aggregate_by_source`, `_round_by_source`

Imports needed: `json`, `os`, `re` + `from sse_parsing import parse_response_content, _resolve_read_file_name`

Note: `_PROJECT_ROOT` uses `os.path.dirname(__file__)` — `__file__` will point to `token_analysis.py`, but since all files live in `/workspace/`, the computed path is identical. Safe.

### `export_flows.py` (reduced to ~700 lines, stays as main module)
Keeps: `parse_request_body`, `sanitize_path`, `format_headers`, `_REDACTED_HEADERS`, `write_request`, `write_response`, `_system_prompt_hash`, `redact_flow_files`, `export_flows`, `extract_usage`, `extract_prompts`, `calculate_costs`, `extract_source_attribution`, `summarize_usage`, `main`

Keeps imports: `argparse`, `glob`, `hashlib` (for `_system_prompt_hash`), `json`, `os`, `re` (for `sanitize_path`), `shutil`, mitmproxy

Adds re-export imports at the top:
```python
from model_config import (
    SYSTEM_PROMPT_INDEX, MODEL_PRICING, _SORTED_PREFIXES, AGENT_COLORS,
    get_canonical_model, get_pricing, _agent_color,
)
from sse_parsing import (
    _resolve_read_file_name, _format_tool_params,
    extract_stop_reason, parse_response_content,
    export_parsed_response, export_parsed_responses,
    categorize_output_sources,
)
from token_analysis import (
    count_whitespace_stats,
    READ_TOOLS, WRITE_TOOLS, _PROJECT_ROOT,
    _get_file_path, extract_read_file_whitespace,
    categorize_input_sources, extract_file_ops,
    attribute_tokens, _aggregate_by_source, _round_by_source,
)
```

---

## Symbol-to-Module Mapping

| Symbol | Source Lines | Destination |
|---|---|---|
| `SYSTEM_PROMPT_INDEX` | 15–18 | `model_config.py` |
| `MODEL_PRICING` | 20–30 | `model_config.py` |
| `_SORTED_PREFIXES` | 33 | `model_config.py` |
| `get_canonical_model` | 62–67 | `model_config.py` |
| `get_pricing` | 70–75 | `model_config.py` |
| `AGENT_COLORS` | 1190–1193 | `model_config.py` |
| `_agent_color` | 1196–1200 | `model_config.py` |
| `count_whitespace_stats` | 36–50 | `token_analysis.py` |
| `extract_stop_reason` | 140–173 | `sse_parsing.py` |
| `_resolve_read_file_name` | 446–451 | `sse_parsing.py` |
| `extract_read_file_whitespace` | 454–496 | `token_analysis.py` |
| `categorize_input_sources` | 499–582 | `token_analysis.py` |
| `categorize_output_sources` | 585–678 | `sse_parsing.py` |
| `_format_tool_params` | 681–689 | `sse_parsing.py` |
| `parse_response_content` | 692–772 | `sse_parsing.py` |
| `export_parsed_response` | 775–794 | `sse_parsing.py` |
| `export_parsed_responses` | 797–810 | `sse_parsing.py` |
| `attribute_tokens` | 813–896 | `token_analysis.py` |
| `READ_TOOLS` | 899 | `token_analysis.py` |
| `WRITE_TOOLS` | 900 | `token_analysis.py` |
| `_PROJECT_ROOT` | 903 | `token_analysis.py` |
| `_get_file_path` | 906–913 | `token_analysis.py` |
| `extract_file_ops` | 916–1015 | `token_analysis.py` |
| `_aggregate_by_source` | 1122–1168 | `token_analysis.py` |
| `_round_by_source` | 1171–1187 | `token_analysis.py` |

---

## Incremental Steps (with tests after each)

### Step 1: Extract `model_config.py`
1. Create `model_config.py` with the 7 symbols above (remove inline `import hashlib` from `_agent_color`)
2. In `export_flows.py`: add `from model_config import (...)` after standard lib imports; delete the original definitions
3. **Run `pytest test_export_flows.py`**

### Step 2: Extract `sse_parsing.py`
1. Create `sse_parsing.py` with the 7 symbols above (imports: `json`, `os`)
2. In `export_flows.py`: add `from sse_parsing import (...)` after model_config import; delete original definitions
3. **Run `pytest test_export_flows.py`**

### Step 3: Extract `token_analysis.py`
1. Create `token_analysis.py` with the 11 symbols above (imports: `json`, `os`, `re`, `from sse_parsing import parse_response_content, _resolve_read_file_name`)
2. In `export_flows.py`: add `from token_analysis import (...)` after sse_parsing import; delete original definitions
3. **Run `pytest test_export_flows.py`**

---

## Key Gotchas

- **`re` stays in `export_flows.py`**: `sanitize_path` (which stays) uses `re.sub`; it must not be removed
- **`hashlib` stays in `export_flows.py`**: `_system_prompt_hash` (which stays) uses `hashlib.sha256`
- **Patch targets unchanged**: `@patch("export_flows.glob.glob")`, `@patch("export_flows.FlowReader")`, `@patch("export_flows.FlowWriter")` all target symbols that remain in `export_flows.py`
- **Cross-module deps in `token_analysis.py`**: `categorize_input_sources` and `extract_read_file_whitespace` both call `_resolve_read_file_name`; `extract_file_ops` calls `parse_response_content` — all resolved by the `from sse_parsing import ...` at the top of `token_analysis.py`

## Verification

After all steps:
```bash
pytest test_export_flows.py -v
python3 -c "import export_flows as ef; ef._agent_color('x'); ef._resolve_read_file_name('read_file', {}); ef._system_prompt_hash({}, 'vix')"
```
