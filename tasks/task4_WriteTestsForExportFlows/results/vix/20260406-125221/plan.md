## Implementation Plan

### Overview

The target file is `/workspace/export_flows.py`. The test file will be created at `/workspace/test_export_flows.py` (since there's no `evaluation/usage/` subdirectory -- the file lives at the workspace root).

Neither `pytest` nor `mitmproxy` are installed. The tests must mock mitmproxy imports entirely at module level and install pytest before running. The plan accounts for this by using `sys.modules` patching or a conftest approach.

---

### Key Design Decisions

**1. Mocking mitmproxy at import time**

Since `export_flows.py` imports from `mitmproxy` at the top level, those imports will fail in the test environment. The test file must stub the entire `mitmproxy` namespace before importing the module under test. This is done with `unittest.mock.MagicMock` inserted into `sys.modules` before any import of the module.

Strategy: Use a module-level `sys.modules` patch in the test file before importing `export_flows`, so all tests share the stubbed module.

```python
import sys
from unittest.mock import MagicMock

# Stub mitmproxy before importing module under test
sys.modules['mitmproxy'] = MagicMock()
sys.modules['mitmproxy.io'] = MagicMock()
sys.modules['mitmproxy.exceptions'] = MagicMock()
sys.modules['mitmproxy.http'] = MagicMock()

import export_flows  # now safe to import
```

**2. Filesystem mocking**

For functions that read/write files (`parse_request_body`, `write_request`, `write_response`, `extract_usage`, etc.), use `unittest.mock.patch` with `builtins.open` and `tempfile.TemporaryDirectory` as appropriate. Some functions use `os.walk`, `glob.glob`, `os.makedirs`, `shutil.rmtree` -- these will be patched per-test.

For simpler file-reading functions, prefer `unittest.mock.mock_open` with `patch("builtins.open", mock_open(...))`.

**3. Test grouping**

Tests are organized into classes by functional category for clarity:

- `TestCountWhitespaceStats` -- pure string analysis
- `TestGetCanonicalModel` -- model prefix matching
- `TestGetPricing` -- model pricing lookup
- `TestSanitizePath` -- URL sanitization
- `TestExtractStopReason` -- SSE/JSON parsing logic
- `TestSystemPromptHash` -- hashing with various inputs
- `TestResolveReadFileName` -- tool name resolution
- `TestFormatHeaders` -- header redaction
- `TestFormatToolParams` -- parameter formatting
- `TestParseRequestBody` -- file reading with mock open
- `TestWriteRequest` -- HTTPFlow mock + file writes
- `TestWriteResponse` -- HTTPFlow mock + file writes
- `TestExtractReadFileWhitespace` -- pure JSON body processing
- `TestCategorizeInputSources` -- pure JSON body processing
- `TestCategorizeOutputSources` -- SSE parsing from mock file
- `TestParseResponseContent` -- SSE/non-streaming parsing from mock file
- `TestExportParsedResponse` -- file read + write with mocks
- `TestAttributeTokens` -- pure computation
- `TestAggregateBySource` -- pure aggregation logic
- `TestRoundBySource` -- pure rounding logic
- `TestAgentColor` -- deterministic hash color
- `TestExtractFileOps` -- combined body + response parsing
- `TestCalculateCosts` -- filesystem walk with mock
- `TestExtractUsage` -- SSE + non-streaming parsing from mock files
- `TestExtractPrompts` -- filesystem walk
- `TestRedactFlowFiles` -- FlowReader/FlowWriter mocking
- `TestExportFlows` -- FlowReader mocking + filesystem
- `TestSummarizeUsage` -- complex filesystem walk
- `TestGetFilePath` -- path resolution helper

---

### Detailed Test Cases Per Function

#### `count_whitespace_stats`
- Empty string: all zeros
- Single line, no extra spaces: line_returns=0, unnecessary=0
- Multiple newlines: correct count
- Multiple consecutive spaces (3 spaces = 1 unnecessary): verify formula `len(m)-1`
- Mixed: newlines + multiple spaces
- String with only spaces

#### `get_canonical_model`
- Exact match: `"claude-opus-4"` -> `"claude-opus-4"`
- With date suffix: `"claude-opus-4-5-20250101"` -> `"claude-opus-4-5"` (longest prefix wins)
- Ambiguous prefix resolved by sorted-longest-first: `"claude-opus-4-5"` not matched by `"claude-opus-4"`
- Unknown model: returns `None`
- Empty string: returns `None`

#### `get_pricing`
- Known model exact: returns correct dict
- Known model with suffix: delegates to `get_canonical_model`
- Unknown model: returns `None`

#### `sanitize_path`
- Basic path: strips leading/trailing underscores, replaces `/` with `_`
- Query string stripped: `"/path?query=1"` -> `"path"`
- Special characters removed: only `[a-zA-Z0-9_\-]` kept
- Long path truncated at 80 chars
- Empty string: returns `""`
- Path with only special chars: returns `""`

#### `extract_stop_reason`
- SSE with `message_delta` containing `stop_reason`: returns reason
- SSE with multiple events, only `message_delta` matters
- Non-streaming JSON with `"type": "message"` and `stop_reason`
- No relevant data: returns `"unknown"`
- Malformed JSON in SSE line: skipped gracefully
- `message_delta` present but `stop_reason` is None/absent: falls through to fallback
- Both SSE and non-streaming present: SSE takes precedence

#### `_system_prompt_hash`
- `agent_name="cc"` uses index 2
- `agent_name="vix"` uses index 0
- `agent_name="other"` uses index 0 (default)
- Index out of range (system list too short): returns `None`
- No `system` key: returns `None`
- Empty `text`: returns `None`
- Valid text: returns 12-char hex string

#### `_resolve_read_file_name`
- `"read_file"` with `mode="compress"` -> `"read_file_compressed"`
- `"read_file"` with `mode="original"` -> `"read_file_uncompressed"`
- `"read_file"` with no mode key -> `"read_file_uncompressed"` (default)
- `"read_file"` with non-dict input -> `"read_file_uncompressed"`
- `"Read"` -> `"Read"` (passthrough)
- `"write_file"` -> `"write_file"` (passthrough)

#### `format_headers`
- Normal header: returned as-is
- `x-api-key` header: value replaced with `[REDACTED]`
- `authorization` header: value replaced with `[REDACTED]`
- Mixed headers: only sensitive ones redacted
- Headers are returned as bytes keys (mitmproxy format) -> use mock `.fields`

#### `parse_request_body`
- Valid JSON file: returns dict
- Invalid JSON: returns `None`
- File with valid JSON but non-dict (list): still returned (json.load)
- JSONDecodeError: returns `None`

#### `write_request`
- Valid JSON body: writes pretty-printed JSON
- Invalid JSON body: writes raw body
- Empty body: only headers file written, no request.json
- Header file format: first line is `METHOD URL`, second blank, then headers
- Sensitive headers redacted in header file

#### `write_response`
- Response is `None`: function returns early, no files written
- Valid response with body: writes status line, blank, headers, blank, body
- Response with no body: no blank+body section

#### `extract_read_file_whitespace`
- No messages: returns all zeros
- `read_file` tool result with whitespace: counts correctly
- `Read` tool result: counted
- `write_file` tool result: not counted
- Tool result with list content: concatenated
- Tool result with string content: used directly
- Multiple reads: summed

#### `categorize_input_sources`
- Empty messages: tool_results and tool_calls are empty
- Last user message tool_result -> cache_write
- Earlier user message tool_result -> cache_read
- Second-to-last assistant message tool_use -> cache_write
- Earlier assistant tool_use -> cache_read
- `total_chars` equals `len(json.dumps(body))`
- Mixed tools: multiple tool types accumulate separately

#### `categorize_output_sources`
- SSE with text blocks: sums `llm_text`
- SSE with tool_use blocks: categorized by tool name
- `input_json_delta` accumulated correctly
- Non-streaming fallback: parses single JSON message
- Empty file / no SSE and no message: returns zeros
- `read_file` with compress mode resolved via `_resolve_read_file_name`

#### `parse_response_content`
- SSE: text block reconstructed
- SSE: tool_use block with input JSON reconstructed
- Non-streaming: text block extracted
- Non-streaming: tool_use block extracted
- Invalid JSON delta: `input_data` defaults to `{}`
- Multiple blocks in order

#### `export_parsed_response`
- Text block: written as-is
- Tool use block: formatted with params
- Empty blocks list: returns `False`
- Mixed text and tool_use: both in output
- Returns `True` when blocks found

#### `attribute_tokens`
- Zero `total_chars`: input section skipped
- Zero `output_tokens`: output section skipped
- Proportional distribution: fractions computed correctly
- `pricing=None`: input attribution skipped
- Tool results and tool calls both attributed
- Output: `llm_text` and `tool_calls` sections computed

#### `_aggregate_by_source`
- Tool results accumulated across multiple calls
- Tool calls accumulated
- `llm_text` in output accumulated
- `tool_calls` in output accumulated with `__total`
- New keys created on first encounter
- Non-dict entries skipped

#### `_round_by_source`
- Input `tool_results` dollars rounded to 6 decimal places
- Input `tool_calls` dollars rounded
- Output `llm_text` dollars rounded
- Output `tool_calls` dollars rounded
- Missing sections handled gracefully

#### `_agent_color`
- Known agent `"vix"`: from `AGENT_COLORS` dict
- Known agent `"cc"`: from `AGENT_COLORS` dict
- Unknown agent: deterministic hex color `#xxxxxx` format
- Same unknown name always produces same color

#### `extract_usage`
- SSE `message_delta` usage extracted
- Non-streaming message usage extracted
- `timing.json` present: merged into usage and file deleted
- `timing.json` absent: just usage written
- No usage found: warning printed, no `usage.json` written
- Token fields filtered to `TOKEN_FIELDS` only

#### `extract_prompts`
- System prompt with text blocks: written to `system_prompt.md`
- No system key: no file written
- First user message with text content: written to `first_user_message.md`
- User message with list content
- User message with string content (no text blocks written in that path)
- No user messages: no file written
- Multiple user messages: only first used

#### `calculate_costs`
- Known model: computes correct cost breakdown
- Unknown model: warning printed, skipped
- Model key absent in request: skipped
- Canonical model name stored in usage
- Token keys removed from usage after cost computation
- Cost fields correctly rounded

#### `redact_flow_files`
- No `.flow` files: returns immediately
- Flow with `x-api-key`: redacted in-place
- Flow with `authorization`: redacted in-place  
- Flow with neither: not rewritten
- `FlowReadException`: skipped with message
- Count reported correctly

#### `export_flows`
- No `.flow` files: prints message and returns
- Flow with `/count_token` URL: skipped
- Flow with `quota` message: skipped
- `cc` agent: step boundary on system prompt hash change
- Non-`cc` agent: step boundary on `end_turn` stop_reason
- `FlowReadException`: skipped
- Directory for each flow created, existing removed

#### `summarize_usage`
- Directory with no agent subdirs: no output
- Agent dir without numbered subdirs: skipped
- Costs accumulated across steps and models
- `by_source` aggregated
- `read_file_whitespace` aggregated
- `file_ops` aggregated with deduplication
- Timing: `wall_clock_ms` and `avg_duration_ms` computed
- Summary JSON written to `{agent_dir}/usage.json`
- `_agent_color` used for unknown agents

---

### Implementation Approach

The test file structure:

```
/workspace/test_export_flows.py
```

**File header**: stub `sys.modules` for mitmproxy, then import `export_flows`. Import `pytest`, `json`, `os`, `tempfile`, `unittest.mock`.

**Fixtures**:
- `tmp_dir`: `tempfile.TemporaryDirectory` for filesystem tests
- `mock_http_flow`: factory fixture returning a configured `MagicMock` mimicking `HTTPFlow`

**Helper functions** (module-level, prefixed `_make_`):
- `_make_sse_response(events)`: builds SSE-format string from list of event dicts
- `_make_mock_flow(method, url, body, response_status, response_body, headers)`: creates mock HTTPFlow
- `_make_headers_mock(fields)`: creates mock headers object with `.fields` attribute

**Per-class test methods** follow the cases listed above.

**Edge case priorities** (for >80% coverage):
- Every branch in `extract_stop_reason` (SSE path, non-streaming path, "unknown" return)
- Every branch in `categorize_input_sources` (last user idx, second-to-last, cache_write vs cache_read)
- Both `found_sse=True` and `found_sse=False` paths in `categorize_output_sources` and `parse_response_content`
- `total_chars > 0` and `== 0` branches in `attribute_tokens`
- Step boundary logic for `cc` vs non-`cc` in `export_flows`

---

### Critical Files for Implementation

- `/workspace/export_flows.py` - The source file under test; all test cases derived from its logic
- `/workspace/test_export_flows.py` - The new test file to be created (does not yet exist)