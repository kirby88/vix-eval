## Plan: Refactor `export_flows.py` into Smaller Modules

### Overview

The file `/workspace/export_flows.py` is approximately 800 lines and contains several distinct concerns mixed together. The refactoring will split it into cohesive modules while keeping the public API and `main()` function exactly as before. The original `export_flows.py` will become a thin facade that imports and re-exports everything from the submodules.

### Analysis of Current Structure

The file contains these logical groups:

1. **Constants / configuration** — `SYSTEM_PROMPT_INDEX`, `MODEL_PRICING`, `_SORTED_PREFIXES`, `AGENT_COLORS`, `READ_TOOLS`, `WRITE_TOOLS`, `_PROJECT_ROOT`, `_REDACTED_HEADERS`
2. **Model utilities** — `get_canonical_model`, `get_pricing`, `_agent_color`
3. **Path/string utilities** — `sanitize_path`, `count_whitespace_stats`, `_resolve_read_file_name`, `_format_tool_params`, `_get_file_path`
4. **Flow I/O** — `redact_flow_files`, `export_flows`, `write_request`, `write_response`, `format_headers`
5. **Response parsing** — `extract_stop_reason`, `parse_response_content`, `export_parsed_response`, `export_parsed_responses`, `categorize_output_sources`
6. **Usage/cost extraction** — `extract_usage`, `calculate_costs`, `extract_prompts`
7. **Source attribution** — `extract_read_file_whitespace`, `categorize_input_sources`, `attribute_tokens`, `extract_file_ops`, `extract_source_attribution`
8. **Summary aggregation** — `_aggregate_by_source`, `_round_by_source`, `summarize_usage`
9. **Entry point** — `main()`

### Target Module Structure

```
/workspace/
  export_flows.py           (thin facade — unchanged public API, re-exports all)
  flows/
    __init__.py             (empty or minimal)
    _constants.py           (group 1: all constants and lookup tables)
    _models.py              (group 2: model/pricing utilities)
    _utils.py               (group 3: path/string utilities)
    _io.py                  (group 4: flow I/O — read/write flow files)
    _response.py            (group 5: response parsing)
    _extraction.py          (groups 6+7: usage, costs, prompts, attribution)
    _summary.py             (group 8: aggregation and summarize_usage)
```

### Detailed Implementation Steps

Each step ends with running the full test suite to verify no breakage.

---

**Step 1: Create `flows/_constants.py`**

Move all module-level constants into this file:
- `SYSTEM_PROMPT_INDEX`
- `MODEL_PRICING`
- `_SORTED_PREFIXES`
- `AGENT_COLORS`
- `READ_TOOLS`
- `WRITE_TOOLS`
- `_PROJECT_ROOT`
- `_REDACTED_HEADERS`

No imports from other `flows/` modules — this is the leaf dependency.

Run tests.

---

**Step 2: Create `flows/__init__.py`**

Empty file (just makes `flows` a package).

Run tests.

---

**Step 3: Create `flows/_models.py`**

Move model/pricing utilities:
- `get_canonical_model(model_id)`
- `get_pricing(model_id)`
- `_agent_color(name)`

Imports: `flows._constants` (`MODEL_PRICING`, `_SORTED_PREFIXES`, `AGENT_COLORS`), `hashlib`.

Run tests.

---

**Step 4: Create `flows/_utils.py`**

Move string/path helpers:
- `count_whitespace_stats(text)`
- `sanitize_path(path)`
- `_resolve_read_file_name(name, tool_input)`
- `_format_tool_params(input_data)`
- `_get_file_path(input_data)`

Imports: `re`, `json`, `os`, `flows._constants` (`_PROJECT_ROOT`).

Run tests.

---

**Step 5: Create `flows/_io.py`**

Move flow read/write functions:
- `format_headers(headers)`
- `write_request(flow, directory)`
- `write_response(flow, directory)`
- `redact_flow_files(directory)`
- `export_flows(input_dir, output_dir)`

Imports: `glob`, `json`, `os`, `shutil`, `hashlib`, `mitmproxy.*`, `flows._constants` (`_REDACTED_HEADERS`, `SYSTEM_PROMPT_INDEX`), `flows._response` (`extract_stop_reason`), `flows._utils` (`sanitize_path` is not used in these functions but `_system_prompt_hash` is a private helper used only by `export_flows` — keep it in `_io.py`).

Note: `_system_prompt_hash` is a private helper only called from `export_flows()` — it moves to `_io.py` alongside it.

Run tests.

---

**Step 6: Create `flows/_response.py`**

Move response-parsing functions:
- `extract_stop_reason(response_raw)`
- `parse_response_content(response_path)`
- `export_parsed_response(response_path, output_path)`
- `export_parsed_responses(directory)`
- `categorize_output_sources(response_path)`

Imports: `json`, `os`, `flows._utils` (`_resolve_read_file_name`, `_format_tool_params`).

Run tests.

---

**Step 7: Create `flows/_extraction.py`**

Move token/cost/file-op extraction functions:
- `extract_usage(directory)`
- `extract_prompts(directory)`
- `calculate_costs(directory)`
- `extract_read_file_whitespace(body)`
- `categorize_input_sources(body)`
- `attribute_tokens(input_sources, output_sources, usage, pricing)`
- `extract_file_ops(body, response_path)`
- `extract_source_attribution(directory)`

Imports: `json`, `os`, `flows._constants` (`READ_TOOLS`, `WRITE_TOOLS`), `flows._models` (`get_pricing`, `get_canonical_model`), `flows._utils` (`parse_request_body`, `_resolve_read_file_name`, `_get_file_path`), `flows._response` (`categorize_output_sources`, `parse_response_content`).

Note: `parse_request_body` is currently in the top-level module — it belongs in `_utils.py` (it's a file-reading utility). Move it there in this step and update references.

Run tests.

---

**Step 8: Create `flows/_summary.py`**

Move aggregation and summary functions:
- `_aggregate_by_source(agg, flow_by_source)`
- `_round_by_source(agg)`
- `summarize_usage(directory)`

Imports: `json`, `os`, `flows._constants` (`AGENT_COLORS`), `flows._models` (`_agent_color`).

Run tests.

---

**Step 9: Rewrite `export_flows.py` as a facade**

Replace the body of `/workspace/export_flows.py` with imports from all submodules, re-exporting everything that was previously defined at module level. The `main()` function stays in this file (or is imported from a submodule — keeping it here is cleaner since it depends on `argparse` and orchestrates all steps).

The facade pattern looks like:

```python
from flows._constants import (
    SYSTEM_PROMPT_INDEX, MODEL_PRICING, _SORTED_PREFIXES,
    AGENT_COLORS, READ_TOOLS, WRITE_TOOLS, _PROJECT_ROOT, _REDACTED_HEADERS,
)
from flows._models import get_canonical_model, get_pricing, _agent_color
from flows._utils import (
    count_whitespace_stats, sanitize_path, parse_request_body,
    _resolve_read_file_name, _format_tool_params, _get_file_path,
)
from flows._io import (
    format_headers, write_request, write_response,
    redact_flow_files, export_flows,
)
from flows._response import (
    extract_stop_reason, parse_response_content,
    export_parsed_response, export_parsed_responses,
    categorize_output_sources,
)
from flows._extraction import (
    extract_usage, extract_prompts, calculate_costs,
    extract_read_file_whitespace, categorize_input_sources,
    attribute_tokens, extract_file_ops, extract_source_attribution,
)
from flows._summary import (
    _aggregate_by_source, _round_by_source, summarize_usage,
)
```

The `main()` function body is unchanged — it uses the names already imported above.

Run tests.

---

**Step 10: Final verification**

Run the full test suite one more time. Confirm all 102 tests pass. Verify `export_flows.main()` can be imported and called without error.

---

### Key Design Decisions

1. **Backward compatibility is guaranteed**: `export_flows.py` re-exports every public name, so any code doing `import export_flows as ef` and calling `ef.extract_usage(...)` etc. continues to work exactly as before. The test file imports `export_flows as ef` and calls all public functions — if all 102 tests pass, external behavior is confirmed unchanged.

2. **Private helpers stay with their callers**: `_system_prompt_hash` (only called from `export_flows()`), `_finalize_file_ops` and `_finalize_timing` (only called from `summarize_usage()`), `_attribute_input_tool` (nested in `attribute_tokens()`), `add_to_bucket`, `empty_bucket`, `round_costs` (nested in `summarize_usage()`) — all stay where they are, just in different files.

3. **`parse_request_body` moves to `_utils.py`**: It's a pure file-reading utility with no dependencies, fitting naturally with other utility functions. All callers (in `_extraction.py`) import it from `_utils.py`, and `export_flows.py` re-exports it for backward compatibility.

4. **No circular imports**: The dependency graph is a DAG — `_constants` has no internal deps, `_models` depends on `_constants`, `_utils` depends on `_constants`, `_io` depends on `_constants` + `_response`, `_response` depends on `_utils`, `_extraction` depends on `_constants` + `_models` + `_utils` + `_response`, `_summary` depends on `_constants` + `_models`.

5. **Steps are incremental with test checkpoints**: Each module creation is a discrete step tested immediately, so any regression is isolated to that step.

---

### Critical Files for Implementation

- `/workspace/export_flows.py` - The facade to rewrite; must re-export all public names to preserve the API
- `/workspace/test_export_flows.py` - The test file to run after each step; all 102 tests must pass throughout
- `/workspace/flows/_constants.py` - Foundation module; all other submodules depend on it
- `/workspace/flows/_extraction.py` - Largest and most complex submodule; most cross-module dependencies
- `/workspace/flows/_io.py` - Contains `export_flows()` which is the central orchestration function