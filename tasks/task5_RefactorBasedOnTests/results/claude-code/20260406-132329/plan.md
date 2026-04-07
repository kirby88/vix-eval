# Refactor export_flows.py into Smaller Modules

## Context

`export_flows.py` is 1430 lines covering five distinct concerns (pricing config, SSE/response parsing, source attribution, summarization, and pipeline orchestration) crammed into a single file. The goal is to split it into focused submodules while keeping all public names accessible via `import export_flows as ef` (required by `test_export_flows.py`).

**Constraint**: Every public function signature, constant, and `main()` must work exactly as before. The test patches `"export_flows.glob.glob"`, `"export_flows.FlowReader"`, and `"export_flows.FlowWriter"` — those names must remain bound in `export_flows`'s own namespace.

---

## Target Structure

Four new underscore-prefixed submodule files (internal helpers):

| File | Contents |
|---|---|
| `_pricing.py` | `SYSTEM_PROMPT_INDEX`, `MODEL_PRICING`, `_SORTED_PREFIXES`, `get_canonical_model`, `get_pricing` |
| `_sse_parser.py` | `_resolve_read_file_name`, `_format_tool_params`, `extract_stop_reason`, `parse_response_content`, `export_parsed_response`, `export_parsed_responses`, `categorize_output_sources` |
| `_attribution.py` | `count_whitespace_stats`, `parse_request_body`, `READ_TOOLS`, `WRITE_TOOLS`, `_PROJECT_ROOT`, `_get_file_path`, `extract_read_file_whitespace`, `categorize_input_sources`, `attribute_tokens`, `extract_file_ops`, `extract_source_attribution` |
| `_summarize.py` | `AGENT_COLORS`, `_agent_color`, `_aggregate_by_source`, `_round_by_source`, `summarize_usage` |

`export_flows.py` keeps: `_REDACTED_HEADERS`, `sanitize_path`, `format_headers`, `write_request`, `write_response`, `redact_flow_files`, `_system_prompt_hash`, `export_flows` (function), `extract_usage`, `extract_prompts`, `calculate_costs`, `main`. Plus it re-exports everything from the four submodules.

**Import graph (no cycles):**
```
_pricing.py       ← (no workspace imports)
_sse_parser.py    ← (no workspace imports)
_attribution.py   ← _sse_parser, _pricing
_summarize.py     ← (no workspace imports)
export_flows.py   ← _pricing, _sse_parser, _attribution, _summarize
```

Use **absolute imports** (`from _pricing import ...`), not relative — these are sibling files in `/workspace/`, not a package.

---

## Implementation Steps

Each step: create/edit the file, immediately add re-exports to `export_flows.py`, then run `pytest test_export_flows.py -v`.

### Step 1 — Extract `_pricing.py`

**Create `/workspace/_pricing.py`**: Copy lines 15–18 (`SYSTEM_PROMPT_INDEX`), 20–30 (`MODEL_PRICING`), 33 (`_SORTED_PREFIXES`), 62–67 (`get_canonical_model`), 70–75 (`get_pricing`). Needs only `sorted()` builtin, no imports.

**Edit `export_flows.py`**:
- Add after existing imports: `from _pricing import SYSTEM_PROMPT_INDEX, MODEL_PRICING, _SORTED_PREFIXES, get_canonical_model, get_pricing`
- Delete the original definitions of those five symbols.

**Run tests.** Exercises: `TestGetCanonicalModel`, `TestGetPricing`, `TestCalculateCosts`.

---

### Step 2 — Extract `_sse_parser.py`

**Create `/workspace/_sse_parser.py`**: Imports `json`, `os`. Copy (in this order): `_resolve_read_file_name` (lines 446–451), `_format_tool_params` (681–689), `extract_stop_reason` (140–173), `parse_response_content` (692–772), `export_parsed_response` (775–794), `export_parsed_responses` (797–810), `categorize_output_sources` (585–678).

(`_resolve_read_file_name` must precede `categorize_output_sources` since it's called there.)

**Edit `export_flows.py`**:
- Add: `from _sse_parser import _resolve_read_file_name, _format_tool_params, extract_stop_reason, parse_response_content, export_parsed_response, export_parsed_responses, categorize_output_sources`
- Delete those seven definitions.

**Run tests.** Exercises: `TestExtractStopReason`, `TestResolveReadFileName`, `TestFormatToolParams`, `TestParseResponseContent`, `TestExportParsedResponse`, `TestCategorizeOutputSources`.

---

### Step 3 — Extract `_attribution.py`

**Create `/workspace/_attribution.py`**: Imports `json`, `os`, `re`. Cross-imports:
```python
from _sse_parser import parse_response_content, _resolve_read_file_name
from _pricing import get_pricing
```

Copy (in this order): `count_whitespace_stats` (36–50), `parse_request_body` (53–59), `READ_TOOLS` (899), `WRITE_TOOLS` (900), `_PROJECT_ROOT` (903 — `__file__` still resolves to `/workspace/`, so path arithmetic unchanged), `_get_file_path` (906–913), `extract_read_file_whitespace` (454–496), `categorize_input_sources` (499–582), `attribute_tokens` (813–896), `extract_file_ops` (916–1015), `extract_source_attribution` (1018–1058).

**Edit `export_flows.py`**:
- Add: `from _attribution import count_whitespace_stats, parse_request_body, READ_TOOLS, WRITE_TOOLS, _PROJECT_ROOT, _get_file_path, extract_read_file_whitespace, categorize_input_sources, attribute_tokens, extract_file_ops, extract_source_attribution`
- Delete those eleven definitions.

**Run tests.** Exercises: `TestCountWhitespaceStats`, `TestParseRequestBody`, `TestGetFilePath`, `TestExtractReadFileWhitespace`, `TestCategorizeInputSources`, `TestAttributeTokens`, `TestExtractFileOps`.

---

### Step 4 — Extract `_summarize.py`

**Create `/workspace/_summarize.py`**: Imports `hashlib`, `json`, `os` at module level. Copy: `AGENT_COLORS` (1190–1193), `_agent_color` (1196–1200, but **remove the inline `import hashlib`** since it's now at module level), `_aggregate_by_source` (1122–1168), `_round_by_source` (1171–1187), `summarize_usage` (1203–1402).

**Edit `export_flows.py`**:
- Add: `from _summarize import AGENT_COLORS, _agent_color, _aggregate_by_source, _round_by_source, summarize_usage`
- Delete those five definitions.

**Run tests.** Exercises: `TestAgentColor`, `TestAggregateBySource`, `TestRoundBySource`, `TestSummarizeUsage`.

---

## Re-export Block in Final `export_flows.py`

The top of `export_flows.py` after all steps:

```python
#!/usr/bin/env python3
"""Export mitmproxy flow files into per-flow directories..."""

import argparse
import glob          # must stay: patched by tests as "export_flows.glob.glob"
import hashlib
import json
import os
import re
import shutil
from mitmproxy.io import FlowReader, FlowWriter   # must stay: patched by tests
from mitmproxy.exceptions import FlowReadException
from mitmproxy.http import HTTPFlow

from _pricing import (
    SYSTEM_PROMPT_INDEX, MODEL_PRICING, _SORTED_PREFIXES,
    get_canonical_model, get_pricing,
)
from _sse_parser import (
    _resolve_read_file_name, _format_tool_params, extract_stop_reason,
    parse_response_content, export_parsed_response, export_parsed_responses,
    categorize_output_sources,
)
from _attribution import (
    count_whitespace_stats, parse_request_body, READ_TOOLS, WRITE_TOOLS,
    _PROJECT_ROOT, _get_file_path, extract_read_file_whitespace,
    categorize_input_sources, attribute_tokens, extract_file_ops,
    extract_source_attribution,
)
from _summarize import (
    AGENT_COLORS, _agent_color, _aggregate_by_source, _round_by_source,
    summarize_usage,
)
```

Remaining body (~370 lines): `_REDACTED_HEADERS`, `sanitize_path`, `format_headers`, `write_request`, `write_response`, `redact_flow_files`, `_system_prompt_hash`, `export_flows`, `extract_usage`, `extract_prompts`, `calculate_costs`, `main`.

---

## Verification

After all steps, run the full test suite:
```bash
pytest test_export_flows.py -v
```

Spot-check re-exports:
```bash
python -c "import export_flows as ef; print(ef.MODEL_PRICING)"
python -c "import export_flows as ef; print(ef.AGENT_COLORS)"
python -c "import export_flows as ef; print(ef.count_whitespace_stats('a  b'))"
python -c "import export_flows as ef; print(ef._resolve_read_file_name('read_file', {}))"
```

All 94 tests should pass after each step and at the end.
