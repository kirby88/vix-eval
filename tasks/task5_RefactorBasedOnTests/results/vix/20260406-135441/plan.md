## Refactoring Plan for `export_flows.py`

### Overview

The file `/workspace/export_flows.py` is a single ~700-line module containing tightly coupled logic across several distinct concerns. The goal is to split it into focused modules while keeping the public API identical. The test file `/workspace/test_export_flows.py` imports `export_flows as ef` and calls functions directly — so all public names must remain importable from `export_flows`.

---

### Analysis of Current Structure

The file contains these logical groupings:

**1. Constants / Configuration**
- `SYSTEM_PROMPT_INDEX`, `MODEL_PRICING`, `_SORTED_PREFIXES`, `AGENT_COLORS`
- `READ_TOOLS`, `WRITE_TOOLS`, `_PROJECT_ROOT`

**2. Model/Pricing utilities** (pure functions, no I/O)
- `get_canonical_model()`, `get_pricing()`

**3. Text/Path utilities** (pure functions, no I/O)
- `count_whitespace_stats()`, `sanitize_path()`, `_resolve_read_file_name()`, `_format_tool_params()`, `_get_file_path()`, `_agent_color()`

**4. HTTP flow I/O** (reads mitmproxy flow objects, writes files)
- `format_headers()`, `write_request()`, `write_response()`, `redact_flow_files()`

**5. SSE/Response parsing** (reads response_raw.txt, pure text parsing)
- `extract_stop_reason()`, `parse_response_content()`, `export_parsed_response()`, `export_parsed_responses()`

**6. Flow export** (orchestrates reading .flow files → per-flow directories)
- `export_flows()`, `_system_prompt_hash()`

**7. Usage/cost analysis** (walks output directories, reads/writes usage.json)
- `extract_usage()`, `calculate_costs()`, `extract_source_attribution()`
- `categorize_input_sources()`, `categorize_output_sources()`, `attribute_tokens()`
- `extract_read_file_whitespace()`, `extract_file_ops()`
- `_aggregate_by_source()`, `_round_by_source()`

**8. Prompts extraction**
- `extract_prompts()`

**9. Summary aggregation**
- `summarize_usage()`

**10. Entry point**
- `main()`

---

### Target Module Structure

```
/workspace/
  export_flows.py           # Thin re-export facade + main()
  flows/
    __init__.py             # Empty or re-exports
    _config.py              # All constants (MODEL_PRICING, AGENT_COLORS, etc.)
    _utils.py               # Pure utility functions (no I/O)
    _http_io.py             # mitmproxy HTTP I/O (format_headers, write_request, etc.)
    _sse_parser.py          # SSE/response parsing (extract_stop_reason, parse_response_content, etc.)
    _exporter.py            # export_flows() and _system_prompt_hash()
    _usage.py               # extract_usage, calculate_costs, extract_source_attribution
    _attribution.py         # categorize_input_sources, categorize_output_sources, attribute_tokens
    _file_ops.py            # extract_file_ops
    _summarize.py           # summarize_usage, _aggregate_by_source, _round_by_source
    _prompts.py             # extract_prompts
```

Then `export_flows.py` becomes:
```python
from flows._config import *
from flows._utils import *
from flows._http_io import *
# ... all public names re-exported
from flows._summarize import summarize_usage
# ... etc.
def main(): ...
```

---

### Sequencing Strategy: Incremental Steps with Tests After Each

The key constraint is: **after each step, all 102 tests must pass**. This means we must be careful about import order and circular dependencies. Each step is a complete, testable unit.

**Step 1: Extract `_config.py`**

Move all constants to `/workspace/flows/_config.py`:
- `SYSTEM_PROMPT_INDEX`, `MODEL_PRICING`, `_SORTED_PREFIXES`, `AGENT_COLORS`, `READ_TOOLS`, `WRITE_TOOLS`, `_PROJECT_ROOT`

In `export_flows.py`, replace with:
```python
from flows._config import (SYSTEM_PROMPT_INDEX, MODEL_PRICING, _SORTED_PREFIXES,
    AGENT_COLORS, READ_TOOLS, WRITE_TOOLS, _PROJECT_ROOT)
```

Run tests. All 102 should pass since these are just data.

**Step 2: Extract `_utils.py`**

Move pure utility functions to `/workspace/flows/_utils.py`:
- `count_whitespace_stats()`, `sanitize_path()`, `get_canonical_model()`, `get_pricing()`, `_resolve_read_file_name()`, `_format_tool_params()`, `_get_file_path()`, `_agent_color()`, `parse_request_body()`

These import only from `_config` and stdlib. In `export_flows.py`, replace with imports from `flows._utils`. 

Run tests. All 102 should pass.

**Step 3: Extract `_sse_parser.py`**

Move SSE/response parsing to `/workspace/flows/_sse_parser.py`:
- `extract_stop_reason()`, `parse_response_content()`, `export_parsed_response()`, `export_parsed_responses()`

These import from `_utils` (`_resolve_read_file_name`, `_format_tool_params`) and stdlib only. In `export_flows.py`, replace with imports.

Run tests.

**Step 4: Extract `_http_io.py`**

Move mitmproxy I/O to `/workspace/flows/_http_io.py`:
- `format_headers()`, `write_request()`, `write_response()`, `redact_flow_files()`

These import from `_config` (`_REDACTED_HEADERS` — note: this is `_REDACTED_HEADERS` defined locally in the current file but conceptually part of config). In `export_flows.py`, replace with imports.

Run tests.

**Step 5: Extract `_exporter.py`**

Move flow export logic to `/workspace/flows/_exporter.py`:
- `_system_prompt_hash()`, `export_flows()`

These import from `_config`, `_utils`, `_http_io`, `_sse_parser`, and mitmproxy. In `export_flows.py`, replace with imports.

Run tests.

**Step 6: Extract `_attribution.py`**

Move token attribution logic to `/workspace/flows/_attribution.py`:
- `categorize_input_sources()`, `categorize_output_sources()`, `attribute_tokens()`, `extract_read_file_whitespace()`

These import from `_utils`, `_config`, `_sse_parser`, and stdlib. In `export_flows.py`, replace with imports.

Run tests.

**Step 7: Extract `_file_ops.py`**

Move file operation tracking to `/workspace/flows/_file_ops.py`:
- `extract_file_ops()`

Imports from `_config`, `_utils`, `_sse_parser`. In `export_flows.py`, replace with imports.

Run tests.

**Step 8: Extract `_usage.py`**

Move usage extraction and cost calculation to `/workspace/flows/_usage.py`:
- `extract_usage()`, `calculate_costs()`, `extract_source_attribution()`

These import from `_utils`, `_config`, `_attribution`, `_file_ops`, `_sse_parser`. In `export_flows.py`, replace with imports.

Run tests.

**Step 9: Extract `_prompts.py`**

Move prompts extraction to `/workspace/flows/_prompts.py`:
- `extract_prompts()`

Imports from `_utils`. In `export_flows.py`, replace with imports.

Run tests.

**Step 10: Extract `_summarize.py`**

Move aggregation to `/workspace/flows/_summarize.py`:
- `_aggregate_by_source()`, `_round_by_source()`, `summarize_usage()`

Imports from `_config`. In `export_flows.py`, replace with imports.

Run tests.

**Step 11: Final cleanup of `export_flows.py`**

After all submodules are extracted, `export_flows.py` contains only:
- All the `from flows.X import Y` re-export statements (preserving public API)
- The `main()` function
- The `if __name__ == "__main__": main()` guard

Run tests one final time to confirm 102/102 pass.

---

### Important Implementation Notes

**1. `_REDACTED_HEADERS` special handling**

The current file defines `_REDACTED_HEADERS = {b"x-api-key", b"authorization"}` as a module-level variable used by both `format_headers()` and `redact_flow_files()`. It must move to `_config.py` alongside other constants.

**2. `__init__.py` for the `flows/` package**

Create `/workspace/flows/__init__.py` as an empty file to make it a package. The submodules import from each other using relative imports (`from flows._config import ...`) or absolute imports.

**3. Test file does `import export_flows as ef`**

The test references names like `ef.count_whitespace_stats`, `ef.MODEL_PRICING`, `ef._resolve_read_file_name`, etc. Every name (public and private) that the tests access must remain importable from `export_flows`. The re-export strategy (importing everything into `export_flows`'s namespace) handles this perfectly.

**4. Circular import risk**

The dependency graph is strictly acyclic:
```
_config (no deps)
_utils -> _config
_sse_parser -> _utils
_http_io -> _config, _utils
_exporter -> _config, _utils, _http_io, _sse_parser
_attribution -> _config, _utils, _sse_parser
_file_ops -> _config, _utils, _sse_parser
_usage -> _utils, _config, _attribution, _file_ops, _sse_parser
_prompts -> _utils
_summarize -> _config
export_flows -> all of the above + main()
```

No cycles.

**5. `_agent_color` imports `hashlib` locally**

Currently `_agent_color` does `import hashlib` inside the function body. When moved to `_utils.py`, just move the import to the top of that module (hashlib is already imported at module level in the current file anyway).

---

### Verification Approach

After each step:
```
python3 -m pytest /workspace/test_export_flows.py -v
```
Expected: 102 passed. Any failure indicates a missing re-export or import error and must be fixed before proceeding to the next step.

---

### Critical Files for Implementation

- `/workspace/export_flows.py` - The facade to be thinned out; must re-export all public/private names the tests access
- `/workspace/test_export_flows.py` - The test suite; must pass 102/102 after every step; defines which names must remain importable from `export_flows`
- `/workspace/flows/_config.py` - First module to create; all constants flow from here; foundation for all other modules
- `/workspace/flows/_utils.py` - Pure utility functions used by nearly every other module; critical dependency
- `/workspace/flows/_summarize.py` - Most complex module to extract (`summarize_usage` is ~150 lines); highest risk of breaking tests