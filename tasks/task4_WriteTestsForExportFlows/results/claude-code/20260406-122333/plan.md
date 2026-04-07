# Plan: Write Tests for export_flows.py

## Context
The file `/workspace/export_flows.py` (1430 lines) exports mitmproxy flow files into structured per-flow directories and performs token usage analysis. The user wants a comprehensive pytest suite at `/workspace/evaluation/usage/test_export_flows.py` achieving ≥80% code coverage. No existing tests, no pytest config. mitmproxy is an external dependency requiring mocking.

## Target file
`/workspace/export_flows.py` — imported as `export_flows` with `sys.path` insertion in test file.

## Test file to create
`/workspace/evaluation/usage/test_export_flows.py`

The test file will use:
- `pytest` + `unittest.mock` (patch, MagicMock)
- `pytest`'s `tmp_path` fixture for real filesystem operations
- Manual mock objects for mitmproxy types (HTTPFlow, headers)

---

## Test Suite Structure

### 1. Pure-logic utility functions (no I/O)

**`count_whitespace_stats`**
- Empty string → all zeros
- String with newlines → correct count
- String with multi-space runs → correct unnecessary count (len-1 per run)
- Mixed content

**`get_canonical_model`**
- Exact match: `"claude-sonnet-4-6"` → `"claude-sonnet-4-6"`
- Date-suffix: `"claude-opus-4-5-20241022"` → `"claude-opus-4-5"` (not `"claude-opus-4"`)
- Longer prefix wins: `"claude-opus-4-5-x"` → `"claude-opus-4-5"` (sorted longest-first)
- Unknown model → None
- Empty string → None

**`get_pricing`**
- Known model with suffix → returns pricing dict
- Unknown model → None

**`sanitize_path`**
- Query string stripped: `"/v1/messages?foo=bar"` → no `?foo=bar`
- Slashes replaced with `_`, leading/trailing stripped
- Special chars removed
- Result truncated at 80 chars

**`_resolve_read_file_name`**
- `"read_file"` + `{"mode": "compress"}` → `"read_file_compressed"`
- `"read_file"` + `{"mode": "original"}` → `"read_file_uncompressed"`
- `"read_file"` + `{}` → `"read_file_uncompressed"` (default)
- `"read_file"` + non-dict input → `"read_file_uncompressed"`
- Other tool name → returned unchanged

**`_format_tool_params`**
- String value → quoted: `key="value"`
- Non-string value → json.dumps: `key=123`
- Mixed types
- Empty dict → empty string

**`_agent_color`**
- Known agents use AGENT_COLORS lookup (vix, cc)
- Unknown agent: deterministic hex via MD5
- Same name called twice → same color

**`_system_prompt_hash`**
- Body with system array at correct index → 12-char hex
- Body missing system key → None
- Index out of range → None
- Empty text at index → None
- `"cc"` uses index 2, `"vix"` uses index 0

**`_get_file_path`**
- `{"file_path": "/abs/path"}` → `/abs/path`
- `{"path": "/abs/path"}` → `/abs/path`
- Relative path → joined with `_PROJECT_ROOT`
- Non-dict → None
- Neither key → None

**`_aggregate_by_source`**
- Tool results accumulated correctly across multiple flows
- Tool calls accumulated correctly
- LLM text accumulated
- Missing keys handled gracefully

**`_round_by_source`**
- Dollar values rounded to 6 decimal places
- Input tool_results, tool_calls, output llm_text, tool_calls all rounded

### 2. File-reading functions (mock `open` or use `tmp_path`)

**`parse_request_body`**
- Valid JSON file → dict returned
- Invalid JSON → None
- Use `tmp_path` for real file writes

**`format_headers`**
- Regular header → `"key: value"`
- `x-api-key` → `"x-api-key: [REDACTED]"`
- `authorization` → `"authorization: [REDACTED]"`
- Uses mock object with `.fields` attribute returning list of `(bytes, bytes)` tuples

**`extract_stop_reason`** (takes string, no file I/O)
- SSE with `message_delta` containing stop_reason
- SSE with compact JSON (`"type":"message_delta"`)
- SSE with spaced JSON (`"type": "message_delta"`)
- Non-streaming JSON with `type==message`
- No matching content → `"unknown"`
- Malformed JSON lines skipped

### 3. File I/O functions (use `tmp_path`)

**`write_request`** (mock HTTPFlow)
- Creates `request_headers.txt` with method + URL + formatted headers
- Creates `request.json` with pretty-printed JSON body
- Creates `request.json` with raw body when JSON parse fails
- No body → no request.json file

**`write_response`** (mock HTTPFlow)
- `flow.response is None` → returns early, no file created
- Valid response → writes `response_raw.txt` with status + headers + body
- Response with no body text → no blank-line+body section

**`extract_usage`** (use `tmp_path`)
- SSE format: extracts from `message_delta` event
- Non-streaming fallback: extracts from JSON `type==message`
- Merges `timing.json` when present and removes it
- Computes `duration_ms` when both timestamps present
- No usage found → warning printed, no `usage.json`
- Filters to only TOKEN_FIELDS

**`extract_prompts`** (use `tmp_path`)
- Extracts system text blocks and joins with `\n\n`
- Finds first user message, concatenates text blocks
- Skips non-text blocks
- Empty system → no `system_prompt.md`
- No user message → no `first_user_message.md`
- Invalid JSON body → warning, skip

**`extract_read_file_whitespace`** (pure logic, dict input)
- Tool use in assistant → tool result in user mapped correctly
- `read_file` with compress mode → `read_file_compressed` matches
- `Read` tool name → matches
- Non-read tool → excluded
- String content in tool result
- List content in tool result (concatenated)
- Missing tool_use_id → "unknown" tool name, doesn't match read filter

**`categorize_input_sources`** (pure logic, dict input)
- Last user message content → cache_write
- Earlier user message content → cache_read
- Second-to-last assistant message tool_use → cache_write
- Other assistant messages → cache_read
- total_chars is length of `json.dumps(body)`
- Empty messages → empty tool_results/tool_calls

**`categorize_output_sources`** (use `tmp_path`)
- SSE: full content_block_start→delta→stop sequence for text block
- SSE: tool_use block with input_json_delta → resolves read_file name
- Multiple blocks at different indices
- Invalid JSON delta → input_data = {}
- Non-streaming fallback for text + tool_use blocks
- Empty file → zeros

**`parse_response_content`** (use `tmp_path`)
- SSE: text block assembled from deltas
- SSE: tool_use block with JSON assembled
- Non-streaming: extracts text and tool_use
- Returns empty list for no content

**`export_parsed_response`** (use `tmp_path`)
- Text block written as-is
- Tool_use block written as `[ToolName(params)]`
- Empty blocks → returns False, no file written
- Returns True on success

**`attribute_tokens`** (pure logic)
- Proportional distribution of output tokens
- Input tokens attributed by cache_write/cache_read chars
- `total_chars == 0` → input section skipped
- `total_output_chars == 0` → output section skipped
- Multiple tools in output → each gets proportional share
- `__total` key added to output tool_calls

**`extract_file_ops`** (use `tmp_path` for response file)
- Read tools: sums chars from tool_result content (string)
- Read tools: sums chars from tool_result content (list of blocks)
- Write tool (`Write`): counts `content` chars
- Edit tool (`Edit`): counts `new_string` chars
- Absolute file_path used directly, relative joined with _PROJECT_ROOT
- File size: OSError → None
- Deduplication via tool_ids map

**`calculate_costs`** (use `tmp_path`)
- Known model: computes correct dollar amounts
- Unknown model → warning, skip
- Missing model field → skip
- Removes top-level token keys
- Adds canonical model name to usage

### 4. mitmproxy-dependent functions (mock FlowReader/FlowWriter)

**`redact_flow_files`**
- No `.flow` files → returns immediately
- HTTP flow with `x-api-key` → redacted + file rewritten
- No sensitive headers → not rewritten
- `FlowReadException` → skip with message
- Non-HTTPFlow object → appended but not modified

**`export_flows`**
- No `.flow` files → prints message and returns
- Skips flows with `/count_token` in URL
- Skips "quota" requests
- `cc` agent: step increments on system prompt hash change
- Non-`cc` agent: step increments on `end_turn` stop_reason
- `FlowReadException` → skip with message
- Correct directory structure: `{agent}/{step}/{request}/`
- `timing.json` written for each flow

### 5. Aggregation / summary function (use `tmp_path`)

**`summarize_usage`**
- Skips non-directory entries
- Skips agent dirs with no numbered subdirs
- Aggregates cost across requests and models
- `by_step` grouped by step subdirectory number
- Timing: `wall_clock_ms` = (max_response_end - min_request_start) * 1000
- `avg_duration_ms` computed
- `file_ops` finalized: tool_ids removed, scalars recomputed
- Known agent color (vix, cc) vs unknown agent (MD5 hash)
- Writes `usage.json` to agent dir

---

## Implementation Notes

### Mock for mitmproxy HTTPFlow
```python
def make_mock_flow(method="POST", url="https://api.anthropic.com/v1/messages",
                   body='{"model":"claude-sonnet-4-6"}',
                   status=200, reason="OK", response_body="",
                   req_ts=1000.0, resp_ts=2000.0):
    flow = MagicMock()
    flow.request.method = method
    flow.request.pretty_url = url
    flow.request.headers.fields = []
    flow.request.get_text.return_value = body
    flow.request.timestamp_start = req_ts
    flow.response.status_code = status
    flow.response.reason = reason
    flow.response.headers.fields = []
    flow.response.get_text.return_value = response_body
    flow.response.timestamp_end = resp_ts
    return flow
```

### Import handling
The test file will use:
```python
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))
import export_flows
from export_flows import ...
```

### SSE response fixture
```python
SSE_RESPONSE = """200 OK

content-type: text/event-stream

data: {"type":"content_block_start","index":0,"content_block":{"type":"text","name":""}}
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}
data: {"type":"content_block_stop","index":0}
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}
"""
```

---

## Verification

Run with coverage:
```bash
cd /workspace && python -m pytest evaluation/usage/test_export_flows.py -v \
  --cov=export_flows --cov-report=term-missing
```

Target: ≥80% line coverage. The main uncovered areas are likely:
- `main()` function (argparse + orchestration) — acceptable to skip
- Some error branches in `summarize_usage` deep nesting
