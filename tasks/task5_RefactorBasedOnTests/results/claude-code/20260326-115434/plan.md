# Plan: Refactor export_flows.py into smaller modules

## Context

`/workspace/export_flows.py` is a 1430-line monolith that processes mitmproxy HTTP flow files for AI assistant token usage analysis. It contains everything: constants, pure utilities, response parsing, source attribution, summarization, and the pipeline orchestration. Splitting it improves navigability, testability, and maintainability.

**Constraints:**
- All public symbols must remain accessible via `import export_flows as ef`
- Tests patch `export_flows.glob.glob`, `export_flows.FlowReader`, `export_flows.FlowWriter` — those must stay in `export_flows.py`
- Run tests after each step; no step should break the suite

## Target module structure

| File | ~Lines | Contents |
|------|--------|----------|
| `flow_models.py` | 35 | Constants: `SYSTEM_PROMPT_INDEX`, `MODEL_PRICING`, `_SORTED_PREFIXES`, `READ_TOOLS`, `WRITE_TOOLS`, `AGENT_COLORS`, `_REDACTED_HEADERS` |
| `flow_utils.py` | 120 | Pure utilities: `count_whitespace_stats`, `parse_request_body`, `get_canonical_model`, `get_pricing`, `sanitize_path`, `format_headers`, `_format_tool_params`, `_get_file_path`, `_PROJECT_ROOT`, `_agent_color`, `_resolve_read_file_name`, `_system_prompt_hash` |
| `response_parser.py` | 240 | `extract_stop_reason`, `parse_response_content`, `export_parsed_response`, `export_parsed_responses`, `categorize_output_sources` |
| `source_attribution.py` | 350 | `extract_read_file_whitespace`, `categorize_input_sources`, `attribute_tokens`, `extract_file_ops`, `extract_source_attribution` |
| `summarize.py` | 200 | `_aggregate_by_source`, `_round_by_source`, `summarize_usage` |
| `export_flows.py` | 280 | mitmproxy I/O (`write_request`, `write_response`, `redact_flow_files`, `export_flows`), pipeline steps (`extract_usage`, `extract_prompts`, `calculate_costs`), re-exports, `main` |

## Implementation steps

Each step: create module → update `export_flows.py` imports → run tests.

### Step 1: `flow_models.py` — constants

**Create** `/workspace/flow_models.py` with no project-level imports:
- `SYSTEM_PROMPT_INDEX`, `MODEL_PRICING`, `_SORTED_PREFIXES` (lines 15–33 of export_flows.py)
- `_REDACTED_HEADERS` (line 87)
- `READ_TOOLS`, `WRITE_TOOLS` (lines 899–900)
- `AGENT_COLORS` (lines 1190–1193)

**In `export_flows.py`**: replace all 8 definitions with:
```python
from flow_models import (
    SYSTEM_PROMPT_INDEX, MODEL_PRICING, _SORTED_PREFIXES,
    _REDACTED_HEADERS, READ_TOOLS, WRITE_TOOLS, AGENT_COLORS,
)
```

### Step 2: `flow_utils.py` — pure utilities

**Create** `/workspace/flow_utils.py`:
```python
import hashlib, json, os, re
from flow_models import MODEL_PRICING, _SORTED_PREFIXES, SYSTEM_PROMPT_INDEX, _REDACTED_HEADERS
```
Move: `count_whitespace_stats`, `parse_request_body`, `get_canonical_model`, `get_pricing`, `sanitize_path`, `format_headers` (lines 36–97), `_resolve_read_file_name` (lines 446–451), `_format_tool_params` (lines 681–689), `_PROJECT_ROOT` + `_get_file_path` (lines 903–913), `_agent_color` (lines 1196–1200), `_system_prompt_hash` (lines 210–221).

Note: `_PROJECT_ROOT` uses `__file__` — safe to move because both files live in `/workspace/`, so `os.path.dirname(__file__)` resolves identically.

**In `export_flows.py`**: add re-export:
```python
from flow_utils import (
    count_whitespace_stats, parse_request_body, get_canonical_model, get_pricing,
    sanitize_path, format_headers, _format_tool_params, _get_file_path, _PROJECT_ROOT,
    _agent_color, _resolve_read_file_name, _system_prompt_hash,
)
```

### Step 3: `response_parser.py` — response parsing

**Create** `/workspace/response_parser.py`:
```python
import json, os
from flow_utils import _format_tool_params, _resolve_read_file_name
```
Move: `extract_stop_reason` (lines 140–173), `categorize_output_sources` (lines 585–678), `parse_response_content` (lines 692–772), `export_parsed_response` (lines 775–794), `export_parsed_responses` (lines 797–810).

**In `export_flows.py`**: add re-export:
```python
from response_parser import (
    extract_stop_reason, parse_response_content, export_parsed_response,
    export_parsed_responses, categorize_output_sources,
)
```

### Step 4: `source_attribution.py` — token attribution + file ops

**Create** `/workspace/source_attribution.py`:
```python
import json, os
from flow_models import READ_TOOLS, WRITE_TOOLS
from flow_utils import count_whitespace_stats, _resolve_read_file_name, get_pricing, _get_file_path, parse_request_body
from response_parser import parse_response_content, categorize_output_sources
```
Move: `extract_read_file_whitespace` (lines 454–496), `categorize_input_sources` (lines 499–582), `attribute_tokens` (lines 813–896), `extract_file_ops` (lines 916–1015), `extract_source_attribution` (lines 1018–1058).

**In `export_flows.py`**: add re-export:
```python
from source_attribution import (
    extract_read_file_whitespace, categorize_input_sources, attribute_tokens,
    extract_file_ops, extract_source_attribution,
)
```

### Step 5: `summarize.py` — usage aggregation

**Create** `/workspace/summarize.py`:
```python
import json, os
from flow_models import AGENT_COLORS
from flow_utils import _agent_color
```
Move: `_aggregate_by_source` (lines 1122–1168), `_round_by_source` (lines 1171–1187), `summarize_usage` (lines 1203–1402).

**In `export_flows.py`**: add re-export:
```python
from summarize import _aggregate_by_source, _round_by_source, summarize_usage
```

## Critical files

- `/workspace/export_flows.py` — modified
- `/workspace/test_export_flows.py` — read-only (tests must pass unchanged)
- Files to create: `flow_models.py`, `flow_utils.py`, `response_parser.py`, `source_attribution.py`, `summarize.py`

## Verification

After each step:
```
python -m pytest /workspace/test_export_flows.py -x -q
```

After all steps, smoke-test the API:
```
python -c "import export_flows as ef; print(ef.MODEL_PRICING, ef.count_whitespace_stats, ef.extract_stop_reason, ef.summarize_usage)"
```
