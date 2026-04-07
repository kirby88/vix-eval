Looking at the codebase, I need to plan a comprehensive test suite for `/workspace/export_flows.py`. The file is at `/workspace/export_flows.py` (not in `evaluation/usage/` — the workspace root is the file's location). The test file should be at `/workspace/test_export_flows.py`.

## Analysis of Functions and Test Strategy

### Pure Logic Functions (No I/O — Highest Priority)

These can be tested directly with no mocking:

1. `count_whitespace_stats(text)` — counts `\n` and consecutive spaces
2. `get_canonical_model(model_id)` — prefix matching against `MODEL_PRICING`
3. `get_pricing(model_id)` — delegates to `get_canonical_model`
4. `sanitize_path(path)` — strips query strings, replaces `/`, removes non-alphanumeric
5. `_system_prompt_hash(body_json, agent_name)` — sha256 of system prompt text
6. `_resolve_read_file_name(name, tool_input)` — mode-based name resolution
7. `_format_tool_params(input_data)` — formats dict as `key=value` pairs
8. `extract_stop_reason(response_raw)` — parses SSE or JSON for stop_reason
9. `attribute_tokens(input_sources, output_sources, usage, pricing)` — token attribution math
10. `_aggregate_by_source(agg, flow_by_source)` — dict accumulation logic
11. `_round_by_source(agg)` — rounds dollar values in nested dicts
12. `_agent_color(name)` — deterministic md5-based hex color
13. `categorize_input_sources(body)` — parses messages, determines cache positions
14. `extract_read_file_whitespace(body)` — parses tool_result blocks from messages

### File I/O Functions (Require `tmp_path` or mocks)

15. `parse_request_body(request_path)` — reads JSON, returns None on error
16. `format_headers(headers)` — needs mock `headers.fields`
17. `write_request(flow, directory)` — needs mock HTTPFlow
18. `write_response(flow, directory)` — needs mock HTTPFlow
19. `extract_usage(directory)` — walks dir, reads `response_raw.txt`
20. `extract_prompts(directory)` — walks dir, reads `request.json`
21. `categorize_output_sources(response_path)` — reads `response_raw.txt`
22. `parse_response_content(response_path)` — reads `response_raw.txt`
23. `export_parsed_response(response_path, output_path)` — reads/writes files
24. `export_parsed_responses(directory)` — walks dir
25. `calculate_costs(directory)` — walks dir, reads/writes `usage.json`/`request.json`
26. `extract_source_attribution(directory)` — walks dir, combines multiple files
27. `_get_file_path(input_data)` — path resolution (can test directly with known paths)
28. `extract_file_ops(body, response_path)` — complex, needs file mocks

### Complex Integration Functions

29. `redact_flow_files(directory)` — needs mitmproxy `FlowReader`/`FlowWriter` mocks
30. `export_flows(input_dir, output_dir)` — needs mitmproxy `FlowReader` mock
31. `summarize_usage(directory)` — complex directory walker
32. `main()` — argparse + calls all functions

## Implementation Plan

### Test File Structure

The test file `/workspace/test_export_flows.py` will be organized into test classes by logical grouping:

```
TestCountWhitespaceStats
TestGetCanonicalModel
TestGetPricing
TestSanitizePath
TestSystemPromptHash
TestResolveReadFileName
TestFormatToolParams
TestExtractStopReason
TestFormatHeaders
TestParseRequestBody
TestWriteRequest
TestWriteResponse
TestExtractUsage
TestExtractPrompts
TestCategorizeInputSources
TestCategorizeOutputSources
TestAttributeTokens
TestParseResponseContent
TestExportParsedResponse
TestCalculateCosts
TestAggregateBySource
TestRoundBySource
TestAgentColor
TestGetFilePath
TestExtractFileOps
TestSummarizeUsage
TestExtractReadFileWhitespace
TestRedactFlowFiles
TestExportFlows
TestMain
```

### Mocking Strategy

**For mitmproxy objects**, create helper factory functions:

```python
def make_mock_flow(method, url, body, status_code, reason, response_body, req_timestamp=None, resp_timestamp=None):
    flow = MagicMock(spec=HTTPFlow)
    flow.request.method = method
    flow.request.pretty_url = url
    flow.request.get_text.return_value = body
    flow.request.timestamp_start = req_timestamp or 1000.0
    flow.request.headers = make_mock_headers([...])
    flow.response.status_code = status_code
    flow.response.reason = reason
    flow.response.get_text.return_value = response_body
    flow.response.timestamp_end = resp_timestamp or 2000.0
    flow.response.headers = make_mock_headers([...])
    return flow

def make_mock_headers(fields_list):
    headers = MagicMock()
    headers.fields = [(k.encode(), v.encode()) for k, v in fields_list]
    return headers
```

**For filesystem operations**, use pytest's `tmp_path` fixture to create real files rather than mocking `open()`. This avoids complex mock setup and tests more realistic behavior.

**For FlowReader**, mock the `FlowReader` class at `export_flows.FlowReader`.

### Detailed Test Cases

#### `TestCountWhitespaceStats`
- Empty string: all zeros
- Single newline: line_returns=1, spaces=0
- Multiple consecutive spaces: unnecessary_space_count correct
- Mixed: both newlines and extra spaces
- No whitespace: all zeros

#### `TestGetCanonicalModel`
- Exact match: `"claude-opus-4-5"` returns `"claude-opus-4-5"`
- With date suffix: `"claude-opus-4-5-20250514"` returns `"claude-opus-4-5"`
- Longer prefix wins over shorter: `"claude-opus-4-5-x"` matches `"claude-opus-4-5"` not `"claude-opus-4"`
- Unknown model: returns `None`
- Empty string: returns `None`

#### `TestGetPricing`
- Known model: returns dict with `input`, `cache_write`, `cache_read`, `output`
- Model with suffix: returns correct dict
- Unknown: returns `None`

#### `TestSanitizePath`
- Query string stripped: `"/path?foo=bar"` → `"path"`
- Slashes become underscores
- Leading/trailing underscores stripped
- Special chars removed
- Long path truncated at 80 chars
- Empty string after sanitization

#### `TestExtractStopReason`
- SSE format with `message_delta` containing `stop_reason`
- SSE format with non-message_delta events (should ignore)
- Non-streaming JSON with `type=message` and `stop_reason`
- Multiple SSE events, returns last `message_delta` stop_reason
- Malformed JSON in SSE lines (should skip)
- No stop_reason found: returns `"unknown"`
- Empty string: returns `"unknown"`

#### `TestSystemPromptHash`
- Valid system with text at correct index for `"cc"` (index 2)
- Valid system with text at correct index for `"vix"` (index 0)
- Unknown agent name defaults to index 0
- Index out of bounds: returns `None`
- No `system` key: returns `None`
- Empty text: returns `None`
- Hash is 12-char hex string

#### `TestResolveReadFileName`
- `"read_file"` with mode `"compress"` → `"read_file_compressed"`
- `"read_file"` with mode `"original"` → `"read_file_uncompressed"`
- `"read_file"` with no mode → `"read_file_uncompressed"`
- `"read_file"` with non-dict input → `"read_file_uncompressed"`
- Other name like `"write_file"` → unchanged
- `"Read"` → unchanged

#### `TestFormatToolParams`
- Empty dict: `""`
- String values use quoted form: `key="value"`
- Non-string values use JSON dumps: `key=123`
- Multiple params: comma-separated

#### `TestParseRequestBody` (uses tmp_path)
- Valid JSON file: returns dict
- Invalid JSON: returns `None`
- File contains only partial JSON: returns `None`

#### `TestFormatHeaders` (uses mock headers)
- Normal headers: formatted as `key: value`
- `x-api-key` header: shows `[REDACTED]`
- `authorization` header: shows `[REDACTED]`
- Mixed: some redacted, some not
- Bytes key/value: decoded properly

#### `TestWriteRequest` (uses tmp_path + mock flow)
- Body is valid JSON: pretty-printed in `request.json`
- Body is not JSON: raw body written
- Empty body: `request.json` not created
- Headers written to `request_headers.txt` with method+URL line

#### `TestWriteResponse` (uses tmp_path + mock flow)
- Normal response: writes status, headers, body
- `response is None`: returns without writing
- No body: written without body section

#### `TestExtractUsage` (uses tmp_path)
- SSE format with `message_delta` usage
- Non-streaming JSON with `usage` in message
- No usage found: prints warning, skips
- With `timing.json`: merges timing, removes timing file
- Without `timing.json`: no timing in output
- Multiple flows in subdirectories

#### `TestExtractPrompts` (uses tmp_path)
- System with text blocks: writes `system_prompt.md`
- No system key: no system_prompt.md
- First user message with text blocks: writes `first_user_message.md`
- User message with non-list content: skips
- No request.json: skips directory
- Invalid JSON in request.json: prints warning

#### `TestCategorizeInputSources`
- Last user message tool_results: go to `cache_write`
- Earlier messages: go to `cache_read`
- Tool use IDs properly mapped to tool names
- `total_chars` is length of full JSON dump
- Empty messages: empty tool_results and tool_calls

#### `TestCategorizeOutputSources` (uses tmp_path)
- SSE with text blocks: counted in `llm_text`
- SSE with tool_use blocks: counted in `tool_calls`
- SSE partial_json accumulation across `input_json_delta` events
- Non-streaming JSON fallback
- Mixed content blocks
- Empty file: zeros

#### `TestAttributeTokens`
- Proportional output token distribution
- Input token distribution by cache position
- Zero total_chars: skips input attribution
- Zero output chars: skips output attribution
- Missing pricing: no attribution
- All token fields present: correct dollar calculation

#### `TestParseResponseContent` (uses tmp_path)
- SSE with text blocks
- SSE with tool_use blocks, JSON accumulated
- Non-streaming fallback
- Malformed JSON: skips
- Empty file: returns `[]`

#### `TestExportParsedResponse` (uses tmp_path)
- Text blocks written as-is
- Tool use blocks formatted with `tool_name(params)`
- No blocks: returns `False`
- With blocks: returns `True`

#### `TestCalculateCosts` (uses tmp_path)
- Known model: computes all cost fields correctly
- Unknown model: prints warning, skips
- No model in body: skips
- Removes token fields, adds `model` canonical name
- Verifies cost math for specific token counts

#### `TestAggregateBySource`
- Accumulates `tool_results` tokens/dollars/chars
- Accumulates `tool_calls` tokens/dollars/chars
- Accumulates `llm_text` output
- Accumulates `tool_calls` output
- Empty flow_by_source: no-op

#### `TestRoundBySource`
- Input tool_results dollars rounded to 6 decimals
- Input tool_calls dollars rounded to 6 decimals
- Output llm_text dollars rounded
- Output tool_calls dollars rounded

#### `TestAgentColor`
- Known agents have fixed colors from `AGENT_COLORS`
- Unknown agent: deterministic hex color based on md5
- Result starts with `#` and is 7 chars

#### `TestGetFilePath`
- Dict with `file_path`: returns it (absolute)
- Dict with `path`: returns it
- Relative path: joined with project root
- Not a dict: returns `None`
- Empty dict: returns `None`

#### `TestExtractFileOps` (uses tmp_path + mock parse_response_content)
- Read tool results properly matched to tool_ids
- Write tool calls (Write, write_file, Edit, edit_file)
- Deduplication via tool_ids
- `file_size` fetched with OSError fallback to None
- Chars for Write from `content`, for Edit from `new_string`

#### `TestSummarizeUsage` (uses tmp_path)
- Creates `usage.json` in agent directory
- Only processes dirs with numbered step subdirs
- Aggregates by_model and by_step correctly
- Finalizes timing (wall_clock_ms, avg_duration_ms)
- Finalizes file_ops (calls, chars, unique counts)
- Colors: known agents get AGENT_COLORS value, unknown get `_agent_color`

#### `TestRedactFlowFiles` (mocks FlowReader/FlowWriter)
- No .flow files: returns early
- Modifies x-api-key in request headers
- Modifies authorization in request headers
- Writes back only modified files
- FlowReadException: prints message, continues
- Non-HTTPFlow objects: appended but not modified

#### `TestExportFlows` (mocks FlowReader + tmp_path)
- No .flow files: prints message, returns
- Skips `/count_token` URLs
- Skips quota messages
- For `cc` agent: step increments on system prompt hash change
- For non-cc agent: step increments on `end_turn` stop_reason
- `FlowReadException`: prints message, continues
- Writes timing.json

#### `TestMain` (mocks all sub-functions + argparse)
- Default directories use script's `data/` dir
- Custom `--input-directory` and `--output-directory`
- All functions called in correct order

### Coverage Targets

Functions accounting for most lines:
- `export_flows`: ~80 lines — tested with multiple scenarios
- `summarize_usage`: ~120 lines — tested with real directory structure
- `extract_source_attribution`: ~30 lines — tested with combined files
- `categorize_input_sources`: ~50 lines — tested with varied message structures
- `categorize_output_sources`: ~60 lines — tested with SSE and non-SSE

### Import Strategy

Since `mitmproxy` is not installed, the test file will use `unittest.mock.patch` and `MagicMock` to mock `mitmproxy.io.FlowReader`, `mitmproxy.io.FlowWriter`, `mitmproxy.exceptions.FlowReadException`, and `mitmproxy.http.HTTPFlow` at the module level using `sys.modules` patching in a conftest or module-level fixture, or by patching them before import.

The cleanest approach: patch `sys.modules` before importing `export_flows` to inject mock modules for `mitmproxy.io`, `mitmproxy.exceptions`, and `mitmproxy.http`.

```python
# At top of test file, before importing export_flows:
import sys
from unittest.mock import MagicMock, patch

# Create mock mitmproxy modules
mock_mitmproxy = MagicMock()
mock_flow_read_exception = type("FlowReadException", (Exception,), {})
mock_mitmproxy.exceptions.FlowReadException = mock_flow_read_exception
sys.modules["mitmproxy"] = mock_mitmproxy
sys.modules["mitmproxy.io"] = mock_mitmproxy.io
sys.modules["mitmproxy.exceptions"] = mock_mitmproxy.exceptions
sys.modules["mitmproxy.http"] = mock_mitmproxy.http

import export_flows  # noqa: E402
```

This allows all tests to run without mitmproxy installed, and individual tests can patch `export_flows.FlowReader`, `export_flows.FlowWriter`, `export_flows.HTTPFlow`, and `export_flows.FlowReadException` as needed.

### Critical Files for Implementation

- `/workspace/export_flows.py` - Source file being tested; all test cases derive from its logic
- `/workspace/test_export_flows.py` - The new test file to create (does not exist yet)