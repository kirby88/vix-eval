## Implementation Plan

### Context

The file to test is `/workspace/export_flows.py`. The task requests the test file at `evaluation/usage/test_export_flows.py`, but since the source file is at `/workspace/export_flows.py` and there is no `evaluation/usage/` directory, the test file will be placed at `/workspace/test_export_flows.py` (alongside the source). This keeps imports simple and pytest discoverable without any path manipulation.

### Testing Strategy

The file has two categories of functions:

**1. Pure logic (no mocking needed):** These can be tested directly with various inputs.
**2. File I/O functions:** These require `unittest.mock` patches (`mock_open`, `patch('os.walk')`, `patch('glob.glob')`, `patch('os.makedirs')`, `patch('shutil.rmtree')`, etc.) plus mock `mitmproxy` objects.

### Mocking mitmproxy

Since `mitmproxy` is not installed in the environment, we must mock the entire import at the module level in `conftest.py` or at the top of the test file using `sys.modules` patching before importing the module under test.

The approach: use `unittest.mock.MagicMock` stubs inserted into `sys.modules` for `mitmproxy`, `mitmproxy.io`, `mitmproxy.exceptions`, and `mitmproxy.http` before `import export_flows`.

### File Structure

Single file: `/workspace/test_export_flows.py`

### Test Classes and Coverage Plan

**Class `TestCountWhitespaceStats`** (function: `count_whitespace_stats`)
- Empty string: all zeros
- Single newlines: correct `line_returns_count`
- Multiple consecutive spaces: correct `unnecessary_space_count`
- Mixed text with both
- Unicode/special characters still counted correctly via `len()`

**Class `TestGetCanonicalModel`** (function: `get_canonical_model`, `get_pricing`)
- Exact match: `"claude-opus-4-5"` -> `"claude-opus-4-5"`
- With date suffix: `"claude-opus-4-5-20250101"` -> `"claude-opus-4-5"`
- Prefix disambiguation: `"claude-opus-4-20250101"` -> `"claude-opus-4"` (not `claude-opus-4-5`)
- Unknown model: returns `None`
- `get_pricing` returns dict for known, `None` for unknown
- Longest-prefix-first ensures `"claude-opus-4-5"` matches before `"claude-opus-4"`

**Class `TestSanitizePath`** (function: `sanitize_path`)
- Query string stripped: `"/path?query=1"` -> `"path"`
- Slashes replaced with underscores
- Leading/trailing underscores stripped
- Non-alphanumeric chars removed
- Truncated at 80 chars
- Empty path

**Class `TestFormatHeaders`** (function: `format_headers`)
- Non-sensitive header passes through
- `x-api-key` is redacted
- `authorization` is redacted
- Mixed sensitive and non-sensitive headers
- Case-insensitive matching for redaction (headers are bytes)
- Empty headers

**Class `TestExtractStopReason`** (function: `extract_stop_reason`)
- SSE format with `message_delta` containing `stop_reason`
- SSE format without `message_delta`
- Non-streaming JSON with `"type":"message"` and `stop_reason`
- Non-streaming JSON without matching type
- `end_turn` value
- `tool_use` value
- Malformed JSON lines skipped
- Empty string returns `"unknown"`
- SSE takes priority over non-streaming fallback

**Class `TestSystemPromptHash`** (function: `_system_prompt_hash`)
- `system` key absent: `None`
- `system` is empty list: `None`
- Index out of bounds: `None`
- Text is empty string: `None`
- `"cc"` agent uses index 2
- `"vix"` agent uses index 0
- Unknown agent defaults to index 0
- Correct sha256 prefix returned (12 chars)
- Different text produces different hash

**Class `TestResolveReadFileName`** (function: `_resolve_read_file_name`)
- `"read_file"` with `mode="compress"` -> `"read_file_compressed"`
- `"read_file"` with `mode="original"` -> `"read_file_uncompressed"`
- `"read_file"` with missing mode key -> `"read_file_uncompressed"`
- `"read_file"` with non-dict input -> `"read_file_uncompressed"`
- Other names pass through unchanged: `"Read"`, `"write_file"`, etc.

**Class `TestFormatToolParams`** (function: `_format_tool_params`)
- String values quoted
- Non-string values json-dumped
- Empty dict
- Multiple params

**Class `TestGetFilePath`** (function: `_get_file_path`)
- Non-dict input returns `None`
- Dict with `"file_path"` key
- Dict with `"path"` key
- Dict with neither key returns `None`
- Absolute path returned as-is
- Relative path joined with `_PROJECT_ROOT`

**Class `TestExtractReadFileWhitespace`** (function: `extract_read_file_whitespace`)
- Empty messages: returns zeroed dict
- Assistant message with `tool_use` block with `read_file` name
- User message with matching `tool_result` content string
- User message with `tool_result` content as list of blocks
- Multiple results accumulated
- Non-read tool results ignored
- `"Read"` tool name included
- `read_file_compressed` and `read_file_uncompressed` included

**Class `TestCategorizeInputSources`** (function: `categorize_input_sources`)
- Empty messages: zero tool results/calls
- Last user message index detection
- Tool results in last user message -> `cache_write_chars`
- Tool results in earlier user messages -> `cache_read_chars`
- Tool uses in second-to-last message -> `cache_write_chars`
- Tool uses in earlier messages -> `cache_read_chars`
- `total_chars` equals `len(json.dumps(body))`
- Multiple tools accumulated separately
- Unknown tool IDs -> `"unknown"` key

**Class `TestAttributeTokens`** (function: `attribute_tokens`)
- Zero total_chars: no input attribution
- Zero input_tokens: no input attribution
- No pricing: no input attribution
- Proportional output token distribution
- `llm_text` and `tool_calls` output attribution
- Zero total_output_chars: no output attribution
- Multiple tool results and calls attributed proportionally
- Dollar rounding to 6 decimal places

**Class `TestAggregateBySource`** (function: `_aggregate_by_source`, `_round_by_source`)
- Empty `flow_by_source`: no changes to agg
- Input `tool_results` accumulated across calls
- Input `tool_calls` accumulated across calls
- Output `llm_text` accumulated
- Output `tool_calls` accumulated
- New tool keys created on first encounter
- `_round_by_source` rounds all dollar values

**Class `TestAgentColor`** (function: `_agent_color`)
- Known agents `"vix"`, `"cc"` use AGENT_COLORS dict (tested via `summarize_usage` indirectly, or directly via the dict)
- `_agent_color("unknown")` returns a hex string starting with `"#"` of length 7
- Deterministic: same name always same color

**Class `TestParseRequestBody`** (function: `parse_request_body`)
- Valid JSON file: returns dict
- Invalid JSON: returns `None`
- `ValueError`: returns `None`
- Uses `mock_open` to avoid real filesystem

**Class `TestWriteRequest`** (function: `write_request`)
- Writes `request_headers.txt` with method, url, headers
- Writes `request.json` when body is valid JSON
- Writes raw body when JSON parse fails
- No `request.json` written when body is empty/None
- Redacted headers appear as `[REDACTED]`

**Class `TestWriteResponse`** (function: `write_response`)
- No-op when `flow.response` is `None`
- Writes status code, reason, headers
- Includes body when present
- Empty body omitted

**Class `TestCategorizeOutputSources`** (function: `categorize_output_sources`)
- SSE with `content_block_start`, `content_block_delta`, `content_block_stop` for text block
- SSE with tool_use block accumulating `input_json_delta`
- SSE `read_file` tool resolved to `read_file_compressed`/`read_file_uncompressed`
- Non-streaming fallback with `"type":"message"` JSON
- Malformed JSON lines skipped
- Empty file returns zeros

**Class `TestParseResponseContent`** (function: `parse_response_content`)
- SSE streaming: text block assembled from deltas
- SSE streaming: tool_use block assembled from json deltas
- Non-streaming fallback: text and tool_use blocks from single message
- No matching content: returns empty list
- Malformed JSON in SSE skipped

**Class `TestExportParsedResponse`** (function: `export_parsed_response`)
- Text blocks written to output
- Tool use blocks formatted with params
- Empty blocks: returns `False`
- Non-empty: returns `True`

**Class `TestExtractUsage`** (function: `extract_usage`)
- SSE message_delta with usage dict: written to `usage.json`
- Non-streaming fallback message with usage
- No usage found: prints warning, skips
- Timing merged when `timing.json` present, then `timing.json` deleted
- Token fields filtered to TOKEN_FIELDS only
- Uses `os.walk` mock

**Class `TestCalculateCosts`** (function: `calculate_costs`)
- Known model: correct cost calculation for all token types
- Unknown model: prints warning, skips
- Missing model key: skips
- Top-level token keys removed from usage
- Canonical model written to usage

**Class `TestExtractFileOps`** (function: `extract_file_ops`)
- Read tool in assistant, result in user: counted
- Write tool in response: counted with content length
- Edit tool: uses `new_string` for chars
- Relative path resolved to absolute via `_PROJECT_ROOT`
- File size lookup (with `OSError` fallback to `None`)
- Multiple calls to same file deduped by `tool_ids`

**Class `TestSummarizeUsage`** (function: `summarize_usage`)
- Skips non-directory entries
- Skips dirs without numbered subdirs
- Aggregates `by_model`, `by_step`, `total`
- Correct `wall_clock_ms` and `avg_duration_ms`
- `_finalize_file_ops` deduplication
- Writes `usage.json` summary

### Mitmproxy Mock Strategy

At the top of the test file, before any import of `export_flows`:

```python
import sys
from unittest.mock import MagicMock, patch, mock_open

# Stub mitmproxy modules
_mitmproxy_mock = MagicMock()
sys.modules['mitmproxy'] = _mitmproxy_mock
sys.modules['mitmproxy.io'] = _mitmproxy_mock.io
sys.modules['mitmproxy.exceptions'] = _mitmproxy_mock.exceptions
sys.modules['mitmproxy.http'] = _mitmproxy_mock.http

import export_flows
```

For `HTTPFlow` isinstance checks inside `export_flows`, we need to ensure `mitmproxy.http.HTTPFlow` is a real class (not a `MagicMock` that always returns `True` for isinstance), so we create a minimal stub class:

```python
class _FakeHTTPFlow:
    pass
_mitmproxy_mock.http.HTTPFlow = _FakeHTTPFlow
```

Then mock flow objects are instances of `_FakeHTTPFlow`.

### Implementation Notes

1. All filesystem interactions in I/O functions are mocked with `patch('builtins.open', mock_open(...))`, `patch('os.walk')`, `patch('os.path.exists')`, `patch('os.makedirs')`, `patch('glob.glob')`, `patch('shutil.rmtree')`, etc.

2. For functions that call `open()` multiple times (like `extract_usage`), use `side_effect` lists on the mock.

3. For `os.walk`, provide a pre-built list as `return_value`.

4. Header mock objects: create a class with `.fields` attribute (list of `(bytes, bytes)` tuples) and `.get()` method.

5. `FlowReadException` and `FlowReader`/`FlowWriter` are accessed from the mocked `mitmproxy` module.

6. Target 80%+ coverage by ensuring all branches are hit: both SSE and non-streaming paths, both `cc` and non-`cc` agent names, quota-skipping logic, `end_turn` vs other stop reasons, etc.

### Critical Files for Implementation

- `/workspace/export_flows.py` - Source file being tested; all function signatures, branches, and logic must be understood from this file
- `/workspace/test_export_flows.py` - New test file to be created (does not exist yet)