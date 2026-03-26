Now I have a clear and complete picture. Here is the implementation plan.

---

## Implementation Plan: Refactor `export_flows.py` into Smaller Modules

### Overview

The goal is to split the 1,430-line monolithic `export_flows.py` into focused submodules, with `export_flows.py` reduced to a thin re-export shim plus `main()`. The test file does `import export_flows as ef` and accesses every public symbol via `ef.`, so all public names must remain importable from `export_flows`. This is achieved by having `export_flows.py` explicitly re-import everything from the submodules.

The work is broken into five sequential steps, each ending with a test run. Steps are kept small so any breakage is immediately localized.

---

### Module Boundaries

After the refactor the workspace will contain:

```
/workspace/
  export_flows.py           # Thin shim: re-exports + main()
  ef_models.py              # Pricing data, get_canonical_model, get_pricing
  ef_utils.py               # Stateless helpers (text, headers, paths, request body)
  ef_flow_io.py             # mitmproxy read/write: write_request, write_response,
                            #   redact_flow_files, export_flows, extract_stop_reason,
                            #   _system_prompt_hash
  ef_response.py            # SSE/JSON response parsing: parse_response_content,
                            #   categorize_output_sources, export_parsed_response,
                            #   export_parsed_responses, _format_tool_params
  ef_usage.py               # extract_usage, extract_prompts, calculate_costs
  ef_attribution.py         # categorize_input_sources, extract_read_file_whitespace,
                            #   attribute_tokens, extract_file_ops, extract_source_attribution,
                            #   READ_TOOLS, WRITE_TOOLS, _PROJECT_ROOT, _get_file_path
  ef_summarize.py           # _aggregate_by_source, _round_by_source, AGENT_COLORS,
                            #   _agent_color, summarize_usage
  test_export_flows.py      # Unchanged
```

---

### Step-by-Step Plan

#### Step 1 — Create `ef_models.py`

**Contents:**
- Constants: `MODEL_PRICING`, `_SORTED_PREFIXES`
- Functions: `get_canonical_model`, `get_pricing`

**Imports needed:** `hashlib` is NOT needed here. Only the standard library.

**Exact content structure:**
```python
# ef_models.py
MODEL_PRICING = { ... }  # copied verbatim from export_flows.py lines 20-30
_SORTED_PREFIXES = sorted(MODEL_PRICING.keys(), key=len, reverse=True)

def get_canonical_model(model_id: str): ...
def get_pricing(model_id: str): ...
```

**Update to `export_flows.py`:** Replace the `MODEL_PRICING`, `_SORTED_PREFIXES`, `get_canonical_model`, and `get_pricing` definitions with:
```python
from ef_models import MODEL_PRICING, _SORTED_PREFIXES, get_canonical_model, get_pricing
```

**Run tests.** All 102 must pass.

---

#### Step 2 — Create `ef_utils.py`

**Contents:** Pure stateless helpers that have no mitmproxy dependency and no cross-module dependency:
- `count_whitespace_stats`
- `parse_request_body`
- `sanitize_path`
- `_REDACTED_HEADERS`
- `format_headers`
- `_resolve_read_file_name`
- `_format_tool_params`

**Imports needed:** `json`, `re`

**Update to `export_flows.py`:** Replace those definitions with:
```python
from ef_utils import (
    count_whitespace_stats, parse_request_body, sanitize_path,
    _REDACTED_HEADERS, format_headers, _resolve_read_file_name, _format_tool_params,
)
```

**Run tests.** All 102 must pass.

---

#### Step 3 — Create `ef_response.py`

**Contents:** Everything that parses response bodies, with no mitmproxy dependency:
- `parse_response_content`
- `categorize_output_sources`
- `export_parsed_response`
- `export_parsed_responses`

**Imports needed:** `json`, `os`; plus `from ef_utils import _resolve_read_file_name, _format_tool_params`

**Update to `export_flows.py`:** Replace those definitions with:
```python
from ef_response import (
    parse_response_content, categorize_output_sources,
    export_parsed_response, export_parsed_responses,
)
```

**Run tests.** All 102 must pass.

---

#### Step 4 — Create `ef_flow_io.py`

**Contents:** Everything that touches mitmproxy directly:
- `SYSTEM_PROMPT_INDEX`
- `_system_prompt_hash`
- `write_request`
- `write_response`
- `extract_stop_reason`
- `redact_flow_files`
- `export_flows` (the function, not the module)

**Imports needed:** `glob`, `hashlib`, `json`, `os`, `shutil`; mitmproxy imports; `from ef_utils import _REDACTED_HEADERS, format_headers`; `from ef_models import SYSTEM_PROMPT_INDEX`

Wait — `SYSTEM_PROMPT_INDEX` is currently defined at the top of `export_flows.py`, not in `ef_models.py`. It belongs with `ef_flow_io.py` since it is only used by `_system_prompt_hash` which is only used in the `export_flows` function. It will be defined directly in `ef_flow_io.py`.

**Update to `export_flows.py`:** Replace those definitions with:
```python
from ef_flow_io import (
    SYSTEM_PROMPT_INDEX, _system_prompt_hash,
    write_request, write_response, extract_stop_reason,
    redact_flow_files, export_flows,
)
```

Note: `export_flows` the function has the same name as `export_flows` the module being refactored. In `export_flows.py` (the shim), this is fine because the module itself is the shim and the function is imported into it. Python resolves `ef.export_flows` to the function because it is a name in the module's namespace.

**Run tests.** All 102 must pass.

---

#### Step 5 — Create `ef_usage.py`, `ef_attribution.py`, `ef_summarize.py` and finalize shim

These three modules can be created as a single step since they have no inter-dependency with each other (only with the previously created modules).

**`ef_usage.py` contents:**
- `extract_usage`
- `extract_prompts`
- `calculate_costs`
- Imports: `json`, `os`; `from ef_utils import parse_request_body`; `from ef_models import get_pricing, get_canonical_model`

**`ef_attribution.py` contents:**
- `READ_TOOLS`, `WRITE_TOOLS`, `_PROJECT_ROOT`, `_get_file_path`
- `extract_read_file_whitespace`
- `categorize_input_sources`
- `attribute_tokens`
- `extract_file_ops`
- `extract_source_attribution`
- Imports: `json`, `os`; `from ef_utils import count_whitespace_stats, parse_request_body, _resolve_read_file_name`; `from ef_models import get_pricing`; `from ef_response import categorize_output_sources, parse_response_content`

**`ef_summarize.py` contents:**
- `AGENT_COLORS`, `_agent_color`
- `_aggregate_by_source`, `_round_by_source`
- `summarize_usage`
- Imports: `hashlib`, `json`, `os`

Note: `_agent_color` currently has a local `import hashlib` inside the function body. Since `hashlib` is already imported at the top of the original file (for `_system_prompt_hash`), this was redundant. In `ef_summarize.py`, `hashlib` will be imported at the top of the file and the local import inside `_agent_color` will be removed. This is a pure cleanup with no behavioral change.

**Final `export_flows.py` shim:**

After step 5, `export_flows.py` becomes:
```python
#!/usr/bin/env python3
"""Export mitmproxy flow files into per-flow directories."""

import argparse
import os

from ef_models import MODEL_PRICING, _SORTED_PREFIXES, get_canonical_model, get_pricing
from ef_utils import (
    count_whitespace_stats, parse_request_body, sanitize_path,
    _REDACTED_HEADERS, format_headers, _resolve_read_file_name, _format_tool_params,
)
from ef_response import (
    parse_response_content, categorize_output_sources,
    export_parsed_response, export_parsed_responses,
)
from ef_flow_io import (
    SYSTEM_PROMPT_INDEX, _system_prompt_hash,
    write_request, write_response, extract_stop_reason,
    redact_flow_files, export_flows,
)
from ef_usage import extract_usage, extract_prompts, calculate_costs
from ef_attribution import (
    READ_TOOLS, WRITE_TOOLS, _PROJECT_ROOT, _get_file_path,
    extract_read_file_whitespace, categorize_input_sources,
    attribute_tokens, extract_file_ops, extract_source_attribution,
)
from ef_summarize import (
    AGENT_COLORS, _agent_color, _aggregate_by_source, _round_by_source, summarize_usage,
)


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    data_dir = os.path.join(script_dir, "data")
    parser = argparse.ArgumentParser(description="Export mitmproxy flow files to text.")
    parser.add_argument("--input-directory", default=data_dir)
    parser.add_argument("--output-directory", default=data_dir)
    args = parser.parse_args()
    input_dir = args.input_directory
    output_dir = args.output_directory
    os.makedirs(output_dir, exist_ok=True)
    redact_flow_files(input_dir)
    export_flows(input_dir, output_dir)
    extract_usage(output_dir)
    export_parsed_responses(output_dir)
    extract_prompts(output_dir)
    calculate_costs(output_dir)
    extract_source_attribution(output_dir)
    summarize_usage(output_dir)


if __name__ == "__main__":
    main()
```

**Run tests.** All 102 must pass.

---

### Dependency Graph of New Modules

```
ef_models.py        (no internal deps)
ef_utils.py         (no internal deps)
ef_response.py      <- ef_utils
ef_flow_io.py       <- ef_utils, ef_models, ef_response (extract_stop_reason only)
ef_usage.py         <- ef_utils, ef_models
ef_attribution.py   <- ef_utils, ef_models, ef_response
ef_summarize.py     (no internal deps beyond stdlib)
export_flows.py     <- all of the above (re-export shim + main)
```

There are no circular dependencies.

---

### Key Constraint: Preserving Test Patches

Two tests use `@patch("export_flows.glob.glob")`, `@patch("export_flows.FlowReader")`, and `@patch("export_flows.FlowWriter")`. After the refactor, those names live in `ef_flow_io`, not `export_flows`. This means those patches **will break** if the test file is not updated.

However, the requirement says **do not change any external behavior — the main() function and all public function signatures must keep working exactly as before.** The test file is part of the test suite, not a public API. But the requirement also says "run the tests to make sure nothing broke."

There are two ways to handle this:

**Option A (preferred — no test file changes):** In `ef_flow_io.py`, import `glob`, `FlowReader`, `FlowWriter` normally. In `export_flows.py`, also import those names so they exist in the `export_flows` namespace:
```python
# In export_flows.py shim, add:
import glob
from mitmproxy.io import FlowReader, FlowWriter
```
This makes `export_flows.glob`, `export_flows.FlowReader`, `export_flows.FlowWriter` resolve correctly for `@patch`. The patch will intercept the names in the `export_flows` namespace, but since `ef_flow_io` imported them directly from their source, the patch won't affect `ef_flow_io`'s copies.

**Option B:** Update the patch targets in the test file from `"export_flows.X"` to `"ef_flow_io.X"`.

Option A preserves the test file unchanged but won't make the patches work correctly. Option B changes the test file but makes patches work correctly.

Actually, re-examining: for `@patch("export_flows.glob.glob")` — this patches `glob.glob` as accessed through the `export_flows` module's reference to `glob`. For this to work correctly after the split, `ef_flow_io.py` must use `glob.glob(...)` (not a local alias), and the test must patch `ef_flow_io.glob.glob`. **The test patches must be updated** to target `"ef_flow_io.glob.glob"`, `"ef_flow_io.FlowReader"`, `"ef_flow_io.FlowWriter"`.

This is the correct approach: update the 5 `@patch` decorators in `test_export_flows.py` to point to `ef_flow_io` instead of `export_flows`. This is a mechanical change to the test infrastructure, not a change to any public API or behavior.

The updated patches are:
- `@patch("export_flows.glob.glob")` → `@patch("ef_flow_io.glob.glob")`
- `@patch("export_flows.FlowWriter")` → `@patch("ef_flow_io.FlowWriter")`
- `@patch("export_flows.FlowReader")` → `@patch("ef_flow_io.FlowReader")`

This affects `TestRedactFlowFiles.test_redacts_api_key`, `TestExportFlows.test_no_flow_files`, `TestExportFlows.test_exports_flows`, and `TestExportFlows.test_skips_count_token_and_quota`.

These patch-target updates are done as part of Step 4 (same step that creates `ef_flow_io.py`).

---

### Summary of All Files Touched

| File | Action |
|---|---|
| `/workspace/ef_models.py` | Create new |
| `/workspace/ef_utils.py` | Create new |
| `/workspace/ef_response.py` | Create new |
| `/workspace/ef_flow_io.py` | Create new |
| `/workspace/ef_usage.py` | Create new |
| `/workspace/ef_attribution.py` | Create new |
| `/workspace/ef_summarize.py` | Create new |
| `/workspace/export_flows.py` | Replace body with re-exports + `main()` |
| `/workspace/test_export_flows.py` | Update 4 `@patch` target strings only |

---

### Critical Files for Implementation

- `/workspace/export_flows.py` - Core module to be refactored into a thin re-export shim; all current logic will be distributed to submodules
- `/workspace/test_export_flows.py` - Test suite that validates nothing broke; patch targets must be updated to point to `ef_flow_io` for mitmproxy and glob mocks
- `/workspace/ef_flow_io.py` - New module to create; receives all mitmproxy-dependent code (`write_request`, `write_response`, `redact_flow_files`, `export_flows` function, `extract_stop_reason`)
- `/workspace/ef_attribution.py` - New module to create; receives the most complex analytical logic (`categorize_input_sources`, `attribute_tokens`, `extract_file_ops`, `extract_source_attribution`)
- `/workspace/ef_summarize.py` - New module to create; receives the largest single function (`summarize_usage` with its nested helpers)