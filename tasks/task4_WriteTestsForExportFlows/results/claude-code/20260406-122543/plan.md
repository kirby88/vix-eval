# Plan: Test Suite for export_flows.py

## Context

The source file is at `/workspace/export_flows.py` (not `evaluation/usage/` — that directory doesn't exist). The test file will be created at `/workspace/test_export_flows.py`. The file is a 1430-line mitmproxy data pipeline that exports, parses, and summarizes Claude API interaction flows. Goal: ≥80% code coverage using pytest with mocks for filesystem and mitmproxy dependencies.

## Critical Files

- **Source**: `/workspace/export_flows.py`
- **Test output**: `/workspace/test_export_flows.py`

## Implementation Plan

### Test Structure

Use `pytest` with `unittest.mock`, `pytest`'s `tmp_path` fixture for real-filesystem tests, and `MagicMock` for mitmproxy objects. Group by function with class-based test suites.

---

### 1. Pure Logic Functions (no I/O)

**`count_whitespace_stats`**
- Empty string → all zeros
- String with `\n` chars → correct count
- Run of 2 spaces → unnecessary_space_count = 1
- Run of 4 spaces → unnecessary_space_count = 3
- Multiple runs, mixed content

**`get_canonical_model`**
- Exact match: `"claude-opus-4-5"` → `"claude-opus-4-5"`
- With date suffix: `"claude-opus-4-5-20250410"` → `"claude-opus-4-5"`
- Longest prefix wins: `"claude-opus-4-5-..."` should not match `"claude-opus-4"` first
- Unknown model → `None`
- Empty string → `None`

**`get_pricing`**
- Known model with date suffix → pricing dict with all 4 keys
- Unknown model → `None`

**`sanitize_path`**
- `"/api/v1/messages?key=value"` → `"api_v1_messages"`
- Leading/trailing underscores stripped
- Special chars removed
- Long path (>80 chars) truncated at 80

**`format_headers`** (mock headers with `.fields`)
- Normal header → `"key: value"`
- `b"x-api-key"` → `"x-api-key: [REDACTED]"`
- `b"authorization"` → `"authorization: [REDACTED]"`
- Mixed headers

**`_system_prompt_hash`**
- Valid cc agent (index 2) → 12-char hex string
- Valid vix agent (index 0) → 12-char hex string
- Empty system list → `None`
- Index out of bounds (cc with only 1 item) → `None`
- System item missing "text" field → `None`
- Unknown agent name defaults to index 0

**`extract_stop_reason`** (pure string arg)
- SSE line with `message_delta` and `stop_reason` → returns it
- SSE with `type: "message_delta"` spacing variant → returns it
- Non-streaming `{"type":"message","stop_reason":"end_turn"}` → returns it
- Malformed SSE JSON → skips gracefully
- No matching content → `"unknown"`
- SSE takes priority over non-streaming

**`_resolve_read_file_name`**
- `"read_file"` + `{"mode": "compress"}` → `"read_file_compressed"`
- `"read_file"` + `{"mode": "original"}` → `"read_file_uncompressed"`
- `"read_file"` + no mode → `"read_file_uncompressed"`
- `"Read"` → unchanged
- Other tool name → unchanged

**`extract_read_file_whitespace`**
- Empty messages → all-zero dict
- assistant tool_use `read_file` → user tool_result → whitespace counted
- String content in tool_result
- List content in tool_result (sum text blocks)
- Only `read_file` and `Read` tools counted (not others)

**`categorize_input_sources`**
- Empty body → `total_chars > 0`, empty tool dicts
- Last user message tool_result → `cache_write_chars`
- Earlier user message tool_result → `cache_read_chars`
- Second-to-last message (assistant) tool_use → `cache_write_chars`
- Other assistant message tool_use → `cache_read_chars`

**`attribute_tokens`**
- `total_chars = 0` → `{"input": {}, "output": {}}`
- `pricing = None` → `{"input": {}, "output": {}}`
- Normal case: input proportionally distributed
- Output distributed by LLM text vs tool chars
- Zero output chars → no output attribution

**`_aggregate_by_source`**
- Empty flow → agg unchanged
- First flow → creates entries
- Second flow with same tools → sums values

**`_round_by_source`**
- Dollar values rounded to 6 decimal places
- Works for both input and output sections

**`_agent_color`**
- Returns string starting with `#`
- Deterministic for same input (same name → same color)
- Length: `#` + 6 hex chars

**`_format_tool_params`**
- String value → `key="value"`
- Integer value → `key=123`
- Empty dict → empty string

**`_get_file_path`** (need to mock `_PROJECT_ROOT`)
- Absolute path → returned unchanged
- Relative path → prepended with `_PROJECT_ROOT`
- `file_path` key checked, then `path` key
- Non-dict input → `None`
- Missing keys → `None`

---

### 2. File I/O Functions (use `tmp_path`)

**`parse_request_body`**
- Valid JSON file → dict
- Invalid JSON file → `None`
- `ValueError` on parse → `None`

**`write_request`** (mock HTTPFlow)
- Writes `request_headers.txt` with METHOD URL and headers
- Valid JSON body → pretty-prints to `request.json`
- Invalid JSON body → raw text fallback
- Empty body → no `request.json` created

**`write_response`** (mock HTTPFlow)
- `flow.response = None` → returns early, no file
- Normal response → writes `response_raw.txt` with status, headers, body
- Response with no body → no extra blank line

**`categorize_output_sources`** (write file to `tmp_path`)
- SSE format with text block → correct `llm_text` chars
- SSE format with tool_use block → tool tracked in `tool_calls`
- Non-streaming `{"type":"message"}` fallback
- Empty file → all zeros

**`parse_response_content`** (write file to `tmp_path`)
- SSE text block assembled from deltas → `{"type":"text", "text":...}`
- SSE tool_use block with JSON → `{"type":"tool_use", "name":..., "input":...}`
- Non-streaming fallback → list of blocks
- Empty → empty list

**`export_parsed_response`** (write file to `tmp_path`)
- With content → writes `response_parsed.txt`, returns `True`
- Empty response → returns `False`
- Text block appears as-is
- Tool use formatted as `[Name(key="val")]`

**`export_parsed_responses`** (real dir structure in `tmp_path`)
- Finds all `response_raw.txt` files recursively, exports each

**`extract_usage`** (real dir structure in `tmp_path`)
- SSE `message_delta` with usage → writes `usage.json`
- Non-streaming fallback
- Merges timing from `timing.json`, deletes `timing.json`
- No usage found → prints warning, skips
- Keeps only token fields

**`extract_prompts`** (real dir structure in `tmp_path`)
- Extracts system blocks from `system` array → `system_prompt.md`
- Extracts first user message text → `first_user_message.md`
- Invalid JSON → skips with warning
- No system → no file
- String content (not list) in user message → skip

**`calculate_costs`** (real dir structure in `tmp_path`)
- Known model → computes all 5 cost entries
- Unknown model → prints warning, skips
- No model field → skips
- Removes top-level token keys after calculation
- Sets `model` to canonical name

**`extract_source_attribution`** (real dir structure in `tmp_path`)
- Valid trio of files → writes `by_source`, `read_file_whitespace`, `file_ops` to `usage.json`
- Missing any required file → skips

**`extract_file_ops`** (write `response_raw.txt` to `tmp_path`)
- Read tool in assistant msg → user tool_result → tracked in input
- Write tool in response → tracked in output
- Edit tool (uses `new_string`) vs Write (uses `content`)
- Absolute path returned as-is; relative path gets project root
- `os.path.getsize` failure → `file_size = None`
- Deduplication: same file read twice with different IDs → calls=2

---

### 3. mitmproxy-mocked Functions

**`redact_flow_files`**
- No `.flow` files in dir → returns immediately
- Flow file with `x-api-key` header → redacts, writes back
- `FlowReadException` → prints warning, continues to next file
- Generic exception → prints warning, continues

**`export_flows`** (mock `FlowReader`)
- No `.flow` files → prints message, returns
- Skip flows with `/count_token` in URL
- Skip flows with `quota` as content and no system
- vix agent: `end_turn` → increments step, resets request index
- vix agent: non-end_turn → only increments request index
- cc agent: system prompt hash change → increments step
- cc agent: same hash → no step change
- Writes `timing.json` for each flow
- `FlowReadException` → prints warning, skips file
- Non-HTTPFlow objects skipped

**`summarize_usage`** (real dir structure in `tmp_path`)
- Skips dirs without numbered subdirectories
- Aggregates by_model, by_step, total
- Wall clock time computed from min request_start and max response_end
- Missing timing → wall_clock_ms = 0
- Uses AGENT_COLORS for known agents, `_agent_color` for unknown

---

### Mock Strategy

```python
# Mock mitmproxy headers
class MockHeaders:
    def __init__(self, fields):
        self.fields = fields  # list of (bytes_key, bytes_value)
    def get(self, key):
        for k, v in self.fields:
            if k.lower() == key.lower():
                return v
        return None

# Mock HTTPFlow
flow = MagicMock()
flow.request.method = "POST"
flow.request.pretty_url = "https://api.anthropic.com/v1/messages"
flow.request.headers = MockHeaders([(b"content-type", b"application/json")])
flow.request.get_text.return_value = json.dumps({...})
flow.request.timestamp_start = 1000.0
flow.response.status_code = 200
flow.response.reason = "OK"
flow.response.headers = MockHeaders([])
flow.response.get_text.return_value = "..."
flow.response.timestamp_end = 1001.5
```

For `FlowReader`, mock as context manager yielding flows:
```python
with patch("export_flows.FlowReader") as mock_reader:
    mock_reader.return_value.stream.return_value = iter([mock_flow])
```

---

### Import Structure for Tests

```python
import sys, os
sys.path.insert(0, "/workspace")
# Mock mitmproxy before importing export_flows
sys.modules["mitmproxy"] = MagicMock()
sys.modules["mitmproxy.io"] = MagicMock()
sys.modules["mitmproxy.exceptions"] = MagicMock()
sys.modules["mitmproxy.http"] = MagicMock()
import export_flows
```

---

### Verification

Run: `cd /workspace && python -m pytest test_export_flows.py -v --cov=export_flows --cov-report=term-missing`

Target: ≥80% line coverage. Focus on ensuring all branches in `extract_stop_reason`, `categorize_input_sources`, `categorize_output_sources`, `attribute_tokens`, and `summarize_usage` are hit.
