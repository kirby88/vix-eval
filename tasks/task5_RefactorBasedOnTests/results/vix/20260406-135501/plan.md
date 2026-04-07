## Refactoring Plan for export_flows.py

### Analysis of Current State

The file `/workspace/export_flows.py` is a single 600+ line module containing several distinct functional areas:

1. **Constants and pricing data** - `MODEL_PRICING`, `SYSTEM_PROMPT_INDEX`, `_SORTED_PREFIXES`, `AGENT_COLORS`, `READ_TOOLS`, `WRITE_TOOLS`, `_PROJECT_ROOT`, `_REDACTED_HEADERS`
2. **Model utilities** - `get_canonical_model()`, `get_pricing()`
3. **Path/string utilities** - `sanitize_path()`, `count_whitespace_stats()`, `_resolve_read_file_name()`, `_format_tool_params()`
4. **Flow I/O** - `format_headers()`, `write_request()`, `write_response()`, `redact_flow_files()`, `export_flows()`
5. **Response parsing** - `extract_stop_reason()`, `parse_response_content()`, `export_parsed_response()`, `export_parsed_responses()`, `categorize_output_sources()`
6. **Request analysis** - `parse_request_body()`, `_get_file_path()`, `extract_read_file_whitespace()`, `categorize_input_sources()`, `_system_prompt_hash()`
7. **Usage/cost processing** - `extract_usage()`, `calculate_costs()`, `extract_source_attribution()`, `attribute_tokens()`, `extract_file_ops()`
8. **Summary/aggregation** - `summarize_usage()`, `_aggregate_by_source()`, `_round_by_source()`, `_finalize_file_ops()` (nested), `_finalize_timing()` (nested), `_agent_color()`
9. **CLI entry point** - `main()`

The test file `/workspace/test_export_flows.py` imports everything as `import export_flows as ef`, meaning all public names must remain accessible via that module.

### Design Decision: Modular Split with Re-exports

The safest approach that preserves all external behavior is:

1. Split into sub-modules under a package, OR
2. Split into sibling modules and import everything back into `export_flows.py`

**Chosen approach: Sibling modules with re-exports in export_flows.py**

This is the safest strategy because:
- The test file does `import export_flows as ef` and calls `ef.function_name()`
- All public names must remain accessible as `ef.function_name`
- A flat namespace re-export in `export_flows.py` preserves this without changing any test code
- Each new module is independently testable
- Refactoring is incremental — one module at a time, tests run after each step

### Module Split Plan

The file will be split into 4 new modules (numbered for implementation order):

**Step 1: Extract `models.py`**
- Constants: `MODEL_PRICING`, `SYSTEM_PROMPT_INDEX`, `_SORTED_PREFIXES`, `AGENT_COLORS`
- Functions: `get_canonical_model()`, `get_pricing()`, `_agent_color()`
- No dependencies on other new modules
- Re-export in `export_flows.py` via `from models import *` (or explicit names)

**Step 2: Extract `parsing.py`**
- Constants: `_REDACTED_HEADERS`, `READ_TOOLS`, `WRITE_TOOLS`, `_PROJECT_ROOT`
- Functions: `sanitize_path()`, `count_whitespace_stats()`, `_resolve_read_file_name()`, `_format_tool_params()`, `format_headers()`, `_get_file_path()`, `parse_request_body()`, `extract_stop_reason()`, `_system_prompt_hash()`
- Depends on: nothing from other new modules
- Re-export in `export_flows.py`

**Step 3: Extract `response.py`**
- Functions: `parse_response_content()`, `export_parsed_response()`, `export_parsed_responses()`, `categorize_output_sources()`
- Depends on: `parsing.py` (for `_resolve_read_file_name`, `_format_tool_params`)
- Re-export in `export_flows.py`

**Step 4: Extract `usage.py`**
- Functions: `extract_usage()`, `calculate_costs()`, `extract_source_attribution()`, `attribute_tokens()`, `extract_file_ops()`, `extract_read_file_whitespace()`, `categorize_input_sources()`, `_aggregate_by_source()`, `_round_by_source()`, `summarize_usage()`
- Depends on: `models.py` (for `get_pricing`, `get_canonical_model`, `AGENT_COLORS`, `_agent_color`), `parsing.py` (for `parse_request_body`, `_resolve_read_file_name`, `_get_file_path`, `_system_prompt_hash`), `response.py` (for `parse_response_content`, `categorize_output_sources`)
- Re-export in `export_flows.py`

**Step 5: Slim down `export_flows.py`**
- Keeps: `write_request()`, `write_response()`, `redact_flow_files()`, `export_flows()`, `main()`
- Adds: import re-exports from all 4 new modules so `ef.X` still works for every public name
- Depends on: all 4 new modules

### Implementation Steps (with test runs)

**Step 1**: Create `/workspace/models.py`
- Move `MODEL_PRICING`, `SYSTEM_PROMPT_INDEX`, `_SORTED_PREFIXES`, `AGENT_COLORS`
- Move `get_canonical_model()`, `get_pricing()`, `_agent_color()`
- In `export_flows.py`: add `from models import MODEL_PRICING, SYSTEM_PROMPT_INDEX, AGENT_COLORS, get_canonical_model, get_pricing, _agent_color` at top, remove moved code
- Run tests: `python -m pytest test_export_flows.py -v`

**Step 2**: Create `/workspace/parsing.py`
- Move `_REDACTED_HEADERS`, `READ_TOOLS`, `WRITE_TOOLS`, `_PROJECT_ROOT`
- Move `sanitize_path()`, `count_whitespace_stats()`, `_resolve_read_file_name()`, `_format_tool_params()`, `format_headers()`, `_get_file_path()`, `parse_request_body()`, `extract_stop_reason()`, `_system_prompt_hash()`
- `parsing.py` needs `from models import SYSTEM_PROMPT_INDEX` for `_system_prompt_hash`
- In `export_flows.py`: add `from parsing import ...` for all moved names, remove moved code
- Run tests

**Step 3**: Create `/workspace/response.py`
- Move `parse_response_content()`, `export_parsed_response()`, `export_parsed_responses()`, `categorize_output_sources()`
- `response.py` needs `from parsing import _resolve_read_file_name, _format_tool_params`
- In `export_flows.py`: add `from response import ...` for all moved names, remove moved code
- Run tests

**Step 4**: Create `/workspace/usage.py`
- Move `extract_usage()`, `calculate_costs()`, `extract_source_attribution()`, `attribute_tokens()`, `extract_file_ops()`, `extract_read_file_whitespace()`, `categorize_input_sources()`, `_aggregate_by_source()`, `_round_by_source()`, `summarize_usage()`
- `usage.py` needs imports from `models`, `parsing`, `response`
- In `export_flows.py`: add `from usage import ...` for all moved names, remove moved code
- Run tests

**Step 5**: Clean up `export_flows.py`
- Ensure all public names are re-exported explicitly (not via `*`) so that `ef.X` still works
- Verify `main()` stays in `export_flows.py` and its pipeline calls still work
- Run full test suite one final time

### Key Constraints and Risks

1. **Circular imports**: The dependency graph is strictly one-directional (`models` -> `parsing` -> `response` -> `usage` -> `export_flows`), so no circular imports will occur.

2. **Private names with leading underscore**: The tests access `ef._resolve_read_file_name`, `ef._format_tool_params`, `ef._system_prompt_hash`, `ef._get_file_path`, `ef._agent_color`, `ef._aggregate_by_source`, `ef._round_by_source` directly. These must all be re-exported from `export_flows.py` by explicit name, even though they are "private" by convention.

3. **Nested helper functions**: `summarize_usage()` contains nested functions `empty_bucket()`, `add_to_bucket()`, `round_costs()`, `_finalize_file_ops()`, `_finalize_timing()`. These are implementation details internal to `summarize_usage()` and should stay nested inside it in `usage.py`.

4. **`_SORTED_PREFIXES`**: This is a module-level derived constant (`sorted(MODEL_PRICING.keys(), ...)`). It must be defined in `models.py` after `MODEL_PRICING` is defined.

5. **`_PROJECT_ROOT`**: This uses `os.path.dirname(__file__)`. When moved to `parsing.py`, `__file__` will refer to `parsing.py`'s location — which is the same directory `/workspace/`, so the value is identical.

6. **The `export_flows` function name conflict**: The function `export_flows()` and the module `export_flows.py` share a name. The new sub-modules import from each other by name, not from `export_flows.py` directly, so there is no conflict.

7. **Test for `export_flows()` function**: `TestExportFlows.test_exports_flows` asserts `"Exported"in output` but looking at the actual function body, it prints `f"\n{total} flows to {output_dir}"` not "Exported". This test may already be failing or uses a string not present. This is pre-existing and must not be changed.

### Re-export Strategy in export_flows.py

The explicit imports to add to `export_flows.py` (replacing moved code) will look like:

```python
from models import (
    MODEL_PRICING, SYSTEM_PROMPT_INDEX, AGENT_COLORS,
    get_canonical_model, get_pricing, _agent_color,
)
from parsing import (
    _REDACTED_HEADERS, READ_TOOLS, WRITE_TOOLS,
    sanitize_path, count_whitespace_stats, _resolve_read_file_name,
    _format_tool_params, format_headers, _get_file_path,
    parse_request_body, extract_stop_reason, _system_prompt_hash,
)
from response import (
    parse_response_content, export_parsed_response,
    export_parsed_responses, categorize_output_sources,
)
from usage import (
    extract_usage, calculate_costs, extract_source_attribution,
    attribute_tokens, extract_file_ops, extract_read_file_whitespace,
    categorize_input_sources, _aggregate_by_source, _round_by_source,
    summarize_usage,
)
```

This makes every `ef.X` call in the tests still work, since Python re-exports any name imported at module level.

### Critical Files for Implementation

- `/workspace/export_flows.py` - Core file to refactor; keeps `write_request`, `write_response`, `redact_flow_files`, `export_flows`, `main`, plus re-exports
- `/workspace/test_export_flows.py` - Test file to run after each step; must not be modified
- `/workspace/models.py` - New module to create; first dependency layer (pricing, model lookup)
- `/workspace/parsing.py` - New module to create; second dependency layer (string utils, header formatting, body parsing)
- `/workspace/usage.py` - New module to create; top of dependency chain (cost calculation, aggregation)