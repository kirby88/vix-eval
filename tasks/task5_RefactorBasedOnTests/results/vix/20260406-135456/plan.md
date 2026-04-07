## Plan: Refactor export_flows.py into Smaller Modules

### Overview

The current `/workspace/export_flows.py` is a single ~750-line file containing 8 logical groups of functionality. The goal is to split it into focused modules while keeping all public API surfaces intact. The test file imports as `import export_flows as ef` and calls functions like `ef.count_whitespace_stats(...)`, so `export_flows.py` must continue to re-export everything that was previously directly in it.

### Architecture Decision

The cleanest approach that satisfies "no external behavior change" is the **package-with-facade pattern**:

1. Create a `export_flows/` package directory
2. Move logic into submodules
3. Keep `/workspace/export_flows.py` as a thin facade that imports and re-exports everything from the package

However, this approach has a significant complication: Python cannot have both a `export_flows.py` file and an `export_flows/` directory importable as the same module. The file would shadow the package or vice versa. The facade approach would require deleting `export_flows.py` and replacing it with a directory, which means a single atomic rename — this is risky.

**Better approach: in-place modular decomposition within a package, replacing the file with a package.**

Actually, the simplest and safest approach given the constraint "no external behavior change" is to keep `export_flows.py` as the single entry point but reorganize it internally using a **helper module strategy**:

- Create private helper modules (e.g., `_flow_utils.py`, `_response_parser.py`, etc.)
- `export_flows.py` imports from them and re-exports all public names
- The test file continues to use `import export_flows as ef` unchanged

This is the lowest-risk approach and satisfies the refactoring goal of "better structure and maintainability."

### Module Decomposition Plan

**Step 1: `_models.py`** — Constants and pricing data
- `SYSTEM_PROMPT_INDEX`
- `MODEL_PRICING`
- `_SORTED_PREFIXES`
- `AGENT_COLORS`
- `READ_TOOLS`
- `WRITE_TOOLS`
- `get_canonical_model()`
- `get_pricing()`

**Step 2: `_utils.py`** — Pure utility/helper functions with no heavy dependencies
- `count_whitespace_stats()`
- `sanitize_path()`
- `format_headers()`
- `_REDACTED_HEADERS`
- `_resolve_read_file_name()`
- `_format_tool_params()`
- `_get_file_path()`
- `_agent_color()`
- `_system_prompt_hash()`
- `_PROJECT_ROOT`

**Step 3: `_response_parser.py`** — SSE/JSON response parsing
- `extract_stop_reason()`
- `parse_response_content()`
- `export_parsed_response()`
- `export_parsed_responses()`
- `categorize_output_sources()`

**Step 4: `_flow_io.py`** — mitmproxy flow reading/writing
- `write_request()`
- `write_response()`
- `redact_flow_files()`
- `export_flows()`

**Step 5: `_usage.py`** — Token/cost extraction and analysis
- `parse_request_body()`
- `extract_usage()`
- `calculate_costs()`
- `extract_read_file_whitespace()`
- `categorize_input_sources()`
- `extract_file_ops()`
- `attribute_tokens()`
- `extract_source_attribution()`

**Step 6: `_summary.py`** — Aggregation and summarization
- `_aggregate_by_source()`
- `_round_by_source()`
- `summarize_usage()`

**Step 7: `extract_prompts.py` is a single function** — stays small enough to either live in `_usage.py` or a dedicated `_prompts.py`

### Dependency Graph Between Modules

```
_models.py         (no internal deps)
_utils.py          (imports from _models.py)
_response_parser.py (imports from _utils.py)
_flow_io.py        (imports from _models.py, _utils.py, _response_parser.py)
_usage.py          (imports from _models.py, _utils.py, _response_parser.py)
_summary.py        (imports from _models.py, _utils.py)
export_flows.py    (imports * from all, re-exports everything)
```

### Implementation Steps (Ordered, with Tests After Each)

**Step 1: Create `_models.py`**
- Move constants: `SYSTEM_PROMPT_INDEX`, `MODEL_PRICING`, `_SORTED_PREFIXES`, `AGENT_COLORS`, `READ_TOOLS`, `WRITE_TOOLS`
- Move functions: `get_canonical_model()`, `get_pricing()`
- In `export_flows.py`: `from _models import *` + explicit name imports
- Run tests: `cd /workspace && /root/.local/pipx/venvs/mitmproxy/bin/python -m pytest test_export_flows.py -v`

**Step 2: Create `_utils.py`**
- Move constants: `_REDACTED_HEADERS`, `_PROJECT_ROOT`
- Move functions: `count_whitespace_stats()`, `sanitize_path()`, `format_headers()`, `_resolve_read_file_name()`, `_format_tool_params()`, `_get_file_path()`, `_agent_color()`, `_system_prompt_hash()`
- `_utils.py` imports from `_models.py`
- In `export_flows.py`: add `from _utils import *`
- Run tests

**Step 3: Create `_response_parser.py`**
- Move: `extract_stop_reason()`, `parse_response_content()`, `export_parsed_response()`, `export_parsed_responses()`, `categorize_output_sources()`
- Imports `json`, `os`, `_utils._resolve_read_file_name`
- In `export_flows.py`: add `from _response_parser import *`
- Run tests

**Step 4: Create `_flow_io.py`**
- Move: `write_request()`, `write_response()`, `redact_flow_files()`, `export_flows_impl()` (rename to avoid collision with module)

Wait — there's a naming conflict: the function `export_flows()` has the same name as the module `export_flows.py`. The private module will be named `_flow_io.py`, so this is not a problem. The function `export_flows()` inside `_flow_io.py` is named `export_flows` as before, and `export_flows.py` re-exports it.

- In `export_flows.py`: add `from _flow_io import *`
- Run tests

**Step 5: Create `_usage.py`**
- Move: `parse_request_body()`, `extract_usage()`, `calculate_costs()`, `extract_read_file_whitespace()`, `categorize_input_sources()`, `extract_file_ops()`, `attribute_tokens()`, `extract_source_attribution()`
- Also move `extract_prompts()` here (thematically related — it reads request bodies)
- In `export_flows.py`: add `from _usage import *`
- Run tests

**Step 6: Create `_summary.py`**
- Move: `_aggregate_by_source()`, `_round_by_source()`, `summarize_usage()`
- In `export_flows.py`: add `from _summary import *`
- Run tests

**Step 7: Final cleanup of `export_flows.py`**
- `export_flows.py` becomes: imports + `main()` + explicit `__all__` list
- Keep `main()` directly in `export_flows.py` (it's the entry point, makes sense to keep it there)
- Run full test suite one final time

### Key Implementation Notes

1. **Wildcard imports vs explicit imports**: To preserve `ef.FUNCTION_NAME` access in tests, use explicit `from _module import name1, name2` rather than `from _module import *` to avoid ambiguity and make the facade clear.

2. **Private function re-exports**: Functions prefixed with `_` (like `_system_prompt_hash`, `_aggregate_by_source`) are called by tests directly as `ef._system_prompt_hash(...)`, so they must be re-exported too.

3. **Cross-module internal calls**: When `_flow_io.py` calls `write_request()`, it calls it locally. When `export_flows.py` calls `export_flows()` (the function), it uses the imported version. No circular dependencies.

4. **`_PROJECT_ROOT` in `_utils.py`**: This uses `os.path.dirname(__file__)` — when moved to `_utils.py`, `__file__` will refer to `_utils.py`, not `export_flows.py`. Both are in the same directory (`/workspace/`), so `os.path.normpath(os.path.join(os.path.dirname(__file__), "..", ".."))` will resolve identically. This is safe.

5. **No `__init__.py` needed**: These are all flat files in `/workspace/`, not a package. Python will find them directly when `export_flows.py` imports from them.

6. **Test command**: `/root/.local/pipx/venvs/mitmproxy/bin/python -m pytest test_export_flows.py -v --tb=short`

### Critical Files for Implementation

- `/workspace/export_flows.py` - Facade entry point: will import and re-export all public names from submodules, keep `main()`
- `/workspace/test_export_flows.py` - Test suite to run after each step; must not be modified; defines what "working exactly as before" means
- `/workspace/_models.py` - First new module to create: constants and model pricing
- `/workspace/_utils.py` - Second new module: pure helpers used across all other modules
- `/workspace/_response_parser.py` - Third new module: SSE/JSON parsing logic