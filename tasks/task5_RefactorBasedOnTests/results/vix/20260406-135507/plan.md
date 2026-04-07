## Plan: Refactor `export_flows.py` into Smaller Modules

### Overview

The file `/workspace/export_flows.py` is a ~700-line monolithic script covering six distinct concerns. The goal is to split it into focused modules without changing any public API or behavior, then verify with the test suite after each step.

The test runner command is:
```
/root/.local/pipx/venvs/mitmproxy/bin/python3 -m pytest /workspace/test_export_flows.py --tb=short -q
```

---

### Module Decomposition

The current file has these logical groupings:

**1. Constants and pricing** (lines ~1–35)
- `SYSTEM_PROMPT_INDEX`, `MODEL_PRICING`, `_SORTED_PREFIXES`
- `get_canonical_model()`, `get_pricing()`

**2. Utilities** (lines ~36–80)
- `count_whitespace_stats()`, `sanitize_path()`, `format_headers()`, `_REDACTED_HEADERS`
- `parse_request_body()`, `_resolve_read_file_name()`, `_format_tool_params()`
- `_get_file_path()`, `READ_TOOLS`, `WRITE_TOOLS`, `_PROJECT_ROOT`

**3. Flow I/O** (lines ~80–230)
- `write_request()`, `write_response()`, `extract_stop_reason()`
- `redact_flow_files()`, `export_flows()`, `_system_prompt_hash()`

**4. Response parsing** (lines ~230–360)
- `parse_response_content()`, `export_parsed_response()`, `export_parsed_responses()`
- `categorize_output_sources()`

**5. Usage/cost analysis** (lines ~360–500)
- `extract_usage()`, `extract_prompts()`, `calculate_costs()`
- `extract_read_file_whitespace()`, `categorize_input_sources()`
- `attribute_tokens()`, `extract_source_attribution()`
- `extract_file_ops()`

**6. Summarization** (lines ~500–680)
- `_aggregate_by_source()`, `_round_by_source()`
- `AGENT_COLORS`, `_agent_color()`, `summarize_usage()`

---

### Target Module Structure

```
/workspace/
  export_flows.py          # thin wrapper: imports everything, keeps main()
  flows/
    __init__.py            # re-exports all public symbols
    pricing.py             # MODEL_PRICING, get_canonical_model, get_pricing
    utils.py               # count_whitespace_stats, sanitize_path, format_headers,
                           # parse_request_body, _resolve_read_file_name,
                           # _format_tool_params, _get_file_path, READ_TOOLS, WRITE_TOOLS
    flow_io.py             # write_request, write_response, extract_stop_reason,
                           # redact_flow_files, export_flows, _system_prompt_hash
    response_parsing.py    # parse_response_content, export_parsed_response,
                           # export_parsed_responses, categorize_output_sources
    usage.py               # extract_usage, extract_prompts, calculate_costs,
                           # extract_read_file_whitespace, categorize_input_sources,
                           # attribute_tokens, extract_source_attribution, extract_file_ops
    summarize.py           # _aggregate_by_source, _round_by_source,
                           # AGENT_COLORS, _agent_color, summarize_usage
```

---

### Step-by-Step Implementation Plan

**Step 0: Baseline**
Run tests to confirm 102 tests pass before any changes.

**Step 1: Create `flows/pricing.py`**

Move to new file:
- `MODEL_PRICING` dict
- `_SORTED_PREFIXES` list (derived from `MODEL_PRICING`)
- `get_canonical_model(model_id: str)` function
- `get_pricing(model_id: str)` function

In `export_flows.py`, replace the moved definitions with:
```python
from flows.pricing import MODEL_PRICING, _SORTED_PREFIXES, get_canonical_model, get_pricing
```

Run tests. Expected: 102 pass.

**Step 2: Create `flows/utils.py`**

Move to new file:
- `_REDACTED_HEADERS` set
- `count_whitespace_stats(text)`
- `parse_request_body(request_path: str)`
- `sanitize_path(path: str) -> str`
- `format_headers(headers) -> str`
- `_resolve_read_file_name(name, tool_input)`
- `_format_tool_params(input_data)`
- `READ_TOOLS`, `WRITE_TOOLS` sets
- `_PROJECT_ROOT` constant
- `_get_file_path(input_data)`

Note: `utils.py` needs to import `get_canonical_model` or... actually `_resolve_read_file_name` does not depend on pricing — it only checks `name == "read_file"`. No cross-module dependency issues here.

In `export_flows.py`, replace with:
```python
from flows.utils import (
    _REDACTED_HEADERS, count_whitespace_stats, parse_request_body,
    sanitize_path, format_headers, _resolve_read_file_name,
    _format_tool_params, READ_TOOLS, WRITE_TOOLS, _PROJECT_ROOT, _get_file_path
)
```

Run tests. Expected: 102 pass.

**Step 3: Create `flows/response_parsing.py`**

Move to new file:
- `parse_response_content(response_path)`
- `export_parsed_response(response_path, output_path)`
- `export_parsed_responses(directory: str)`
- `categorize_output_sources(response_path)`

Dependencies in this module: imports `_resolve_read_file_name`, `_format_tool_params` from `flows.utils`; standard library `json`, `os`.

In `export_flows.py`, replace with:
```python
from flows.response_parsing import (
    parse_response_content, export_parsed_response,
    export_parsed_responses, categorize_output_sources
)
```

Run tests. Expected: 102 pass.

**Step 4: Create `flows/flow_io.py`**

Move to new file:
- `SYSTEM_PROMPT_INDEX` dict
- `_system_prompt_hash(body_json, agent_name)`
- `write_request(flow: HTTPFlow, directory: str)`
- `write_response(flow: HTTPFlow, directory: str)`
- `extract_stop_reason(response_raw: str) -> str`
- `redact_flow_files(directory: str)`
- `export_flows(input_dir: str, output_dir: str)`

Dependencies: imports `format_headers`, `_REDACTED_HEADERS` from `flows.utils`; imports `write_request`, `write_response`, `extract_stop_reason` (self-referential within module); imports `extract_stop_reason` for the step-boundary logic; mitmproxy imports `FlowReader`, `FlowWriter`, `FlowReadException`, `HTTPFlow`.

Note: `export_flows` function also calls `write_request`, `write_response`, `extract_stop_reason` — all defined in the same module, no issue.

In `export_flows.py`, replace with:
```python
from flows.flow_io import (
    SYSTEM_PROMPT_INDEX, write_request, write_response,
    extract_stop_reason, redact_flow_files, export_flows
)
```

Note on naming conflict: the function `export_flows` has the same name as the main script. Since the main script `export_flows.py` will import `export_flows` (the function) from `flows.flow_io`, this works fine — the module name and function name are different identifiers in Python.

Run tests. Expected: 102 pass.

**Step 5: Create `flows/usage.py`**

Move to new file:
- `extract_usage(directory: str)`
- `extract_prompts(directory: str)`
- `extract_read_file_whitespace(body)`
- `categorize_input_sources(body)`
- `attribute_tokens(input_sources, output_sources, usage, pricing)`
- `extract_source_attribution(directory: str)`
- `extract_file_ops(body, response_path)`
- `calculate_costs(directory: str)`

Dependencies: imports `parse_request_body`, `_resolve_read_file_name` from `flows.utils`; imports `get_pricing`, `get_canonical_model` from `flows.pricing`; imports `categorize_output_sources`, `parse_response_content` from `flows.response_parsing`; imports `count_whitespace_stats` from `flows.utils`; imports `_get_file_path`, `READ_TOOLS`, `WRITE_TOOLS` from `flows.utils`.

In `export_flows.py`, replace with:
```python
from flows.usage import (
    extract_usage, extract_prompts, extract_read_file_whitespace,
    categorize_input_sources, attribute_tokens, extract_source_attribution,
    extract_file_ops, calculate_costs
)
```

Run tests. Expected: 102 pass.

**Step 6: Create `flows/summarize.py`**

Move to new file:
- `AGENT_COLORS` dict
- `_agent_color(name)`
- `_aggregate_by_source(agg, flow_by_source)`
- `_round_by_source(agg)`
- `summarize_usage(directory: str)`

Dependencies: imports standard library `os`, `json`, `hashlib`; no cross-module dependencies needed except `_aggregate_by_source` and `_round_by_source` are all self-contained within the module.

In `export_flows.py`, replace with:
```python
from flows.summarize import (
    AGENT_COLORS, _agent_color, _aggregate_by_source,
    _round_by_source, summarize_usage
)
```

Run tests. Expected: 102 pass.

**Step 7: Create `flows/__init__.py`**

Re-export all public symbols so any code doing `import export_flows as ef` via `ef.function()` continues to work. The test file does `import export_flows as ef` and accesses all public names via `ef.*`, so `export_flows.py` must continue to expose them all at the top level.

`__init__.py` can be empty or contain `from flows.pricing import *` etc. — but since the test imports `export_flows` (the script), not `flows`, the `__init__.py` just needs to exist for the package to be valid Python.

Run tests. Expected: 102 pass.

**Step 8: Final cleanup of `export_flows.py`**

The resulting `export_flows.py` should be a thin entry point: all imports from the `flows.*` submodules, plus the `main()` function (which does not move). Standard library imports that are no longer needed directly in `export_flows.py` can be removed (they'll be in the submodules).

Run tests. Expected: 102 pass.

---

### Dependency Graph (Import Order)

```
flows/pricing.py       (no internal deps)
flows/utils.py         (no internal deps, imports pricing only for _PROJECT_ROOT — actually none)
flows/response_parsing.py  (imports utils)
flows/flow_io.py       (imports utils, mitmproxy)
flows/usage.py         (imports utils, pricing, response_parsing)
flows/summarize.py     (no internal deps beyond stdlib)
flows/__init__.py      (empty or re-exports)
export_flows.py        (imports from all flows.*)
```

---

### Key Constraints

1. **No behavior changes**: all public function signatures stay identical.
2. **Test import path**: tests do `import export_flows as ef` and call `ef.function_name()` — so `export_flows.py` must re-export every public name via imports.
3. **Private helpers**: names like `_system_prompt_hash`, `_agent_color`, `_aggregate_by_source` are tested directly via `ef._name()` — they must also be importable from `export_flows`.
4. **`_PROJECT_ROOT`**: defined as `os.path.normpath(os.path.join(os.path.dirname(__file__), "..", ".."))` — when moved to `flows/utils.py`, `__file__` will resolve relative to that file's location. Since `flows/` is one level deeper, the path calculation must be adjusted: `os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))` to still resolve to two levels above the workspace.

    Actually, the current value resolves `export_flows.py`'s parent (workspace) then `../..` from there. If moved to `flows/utils.py`, one more `..` is needed. This must be calculated carefully.

    Safest approach: in `flows/utils.py`, compute `_PROJECT_ROOT` as:
    ```python
    _PROJECT_ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
    ```
    Because `__file__` for `flows/utils.py` is `/workspace/flows/utils.py`, so `dirname` is `/workspace/flows`, and `../../..` is `/`.

    Wait — the original is `os.path.join(os.path.dirname(__file__), "..", "..")` where `__file__` is `/workspace/export_flows.py`, giving `/workspace/../..` = parent of parent of workspace. To replicate exactly, from `/workspace/flows/utils.py`, we need `../../..` to go three levels up from `/workspace/flows`, which gives the same result.

    This should be verified in the implementation step, but the path adjustment is the only tricky non-trivial piece.

5. **Run tests after each step** — 8 steps total, 8 test runs required.

---

### Critical Files for Implementation

- `/workspace/export_flows.py` - The main file to be refactored; will become a thin import wrapper keeping `main()` intact
- `/workspace/test_export_flows.py` - Test suite that imports `export_flows as ef` and must continue passing after every step; defines what public API must be preserved
- `/workspace/flows/utils.py` - Most widely depended-upon new module; the `_PROJECT_ROOT` path adjustment is the only subtle behavioral concern
- `/workspace/flows/usage.py` - Largest and most complex new module with the most cross-module dependencies
- `/workspace/flows/flow_io.py` - Contains the core `export_flows` function (name collision with script name requires care) and mitmproxy I/O