## Plan: Comprehensive Test Suite for `/workspace/export_flows.py`

### Overview

The file `/workspace/export_flows.py` contains ~700 lines of Python with the following categories of functions:

1. **Pure logic functions** (no I/O, easiest to test): `count_whitespace_stats`, `get_canonical_model`, `get_pricing`, `sanitize_path`, `format_headers`, `extract_stop_reason`, `_system_prompt_hash`, `_resolve_read_file_name`, `_format_tool_params`, `_agent_color`, `_get_file_path`, `_aggregate_by_source`, `_round_by_source`, `attribute_tokens`

2. **Filesystem-touching functions** (need temp dirs or mocks): `parse_request_body`, `write_request`, `write_response`, `redact_flow_files`, `export_flows`, `extract_usage`, `extract_prompts`, `categorize_output_sources`, `parse_response_content`, `export_parsed_response`, `export_parsed_responses`, `extract_source_attribution`, `calculate_costs`, `summarize_usage`, `extract_file_ops`, `extract_read_file_whitespace`, `categorize_input_sources`

3. **mitmproxy-dependent functions**: `redact_flow_files`, `export_flows`, `write_request`, `write_response`

### Key Findings from Exploration

- The file lives at `/workspace/export_flows.py` (not under `evaluation/usage/`)
- The test file should be at `/workspace/test_export_flows.py` (same directory)
- `pytest` and `mitmproxy` are both installed in the environment
- `mitmproxy.test.tflow` provides `tflow()`, `treq()`, `tresp()` helpers for creating mock HTTP flows
- The `format_headers` output uses `b'header': b'value'` format (bytes in f-strings)
- `_get_file_path` resolves relative paths against `_PROJECT_ROOT` which is `os.path.normpath(os.path.join(os.path.dirname(__file__), '..', '..'))` — resolves to `/` since the file is at `/workspace/export_flows.py`
- `redact_flow_files` prints `"\n{count} flow files"` (not "Redacted API keys in...")
- `export_flows` skips `/count_token` URLs and quota requests
- Step boundaries for `vix` agents = `end_turn` stop reason; for `cc` agents = system prompt hash change at index 2

### Test Architecture

The test file will use:
- `pytest` with `tmp_path` fixture for filesystem operations
- `mitmproxy.test.tflow.{tflow, treq, tresp}` and `mitmproxy.http.Headers` for creating real (not mocked) flow objects
- `mitmproxy.io.FlowWriter` for writing `.flow` files
- `unittest.mock.patch` for patching `glob.glob` and `os.walk` where needed
- `capsys` fixture to capture print output
- `io.BytesIO` for in-memory flow file creation when possible

### Test Groups and Coverage Strategy

**Group 1: Pure Logic Functions (no I/O)**

```
test_count_whitespace_stats:
  - empty string
  - no whitespace
  - only newlines
  - only double spaces
  - mixed newlines and extra spaces
  - triple spaces (counts as 2 unnecessary)

test_get_canonical_model:
  - exact match (claude-opus-4)
  - with date suffix (claude-opus-4-5-20250101)
  - longer prefix matches before shorter (claude-opus-4-5 vs claude-opus-4)
  - unknown model returns None
  - empty string returns None

test_get_pricing:
  - known model returns dict
  - known model with suffix returns dict
  - unknown returns None

test_sanitize_path:
  - strips query string at ?
  - replaces / with _
  - strips leading/trailing underscores
  - removes special chars
  - truncates at 80 chars
  - empty string

test_format_headers:
  - x-api-key is REDACTED
  - authorization is REDACTED
  - other headers pass through
  - case insensitivity of header names (b'X-Api-Key')
  - empty headers

test_extract_stop_reason:
  - SSE with message_delta containing stop_reason
  - SSE without message_delta (returns unknown)
  - non-streaming JSON with type==message
  - non-streaming JSON without type==message
  - empty string returns unknown
  - malformed JSON in SSE is skipped
  - compact JSON key format ("type":"message_delta" vs "type": "message_delta")

test_system_prompt_hash:
  - no system key returns None
  - system is empty list
  - cc agent uses index 2
  - vix agent uses index 0
  - index out of range returns None
  - empty text returns None
  - hash is sha256[:12]

test_resolve_read_file_name:
  - read_file with mode=compress -> read_file_compressed
  - read_file with mode=original -> read_file_uncompressed
  - read_file with no mode -> read_file_uncompressed (default)
  - read_file with non-dict tool_input -> read_file_uncompressed
  - any other name passes through unchanged

test_format_tool_params:
  - empty dict returns empty string
  - string values use quotes
  - non-string values use json.dumps
  - multiple params comma-separated

test_agent_color:
  - known agents: vix returns #7B2FBE... wait, _agent_color is the hash fallback; AGENT_COLORS has vix=#7B2FBE
  - _agent_color for unknown agent returns deterministic hex
  - same name always returns same color

test_get_file_path:
  - file_path key takes precedence over path
  - path key used when file_path absent
  - relative path gets joined with _PROJECT_ROOT
  - absolute path returned as-is
  - non-dict input returns None
  - empty dict returns None

test_aggregate_by_source:
  - aggregates input tool_results tokens/dollars/chars
  - aggregates input tool_calls
  - aggregates output llm_text
  - aggregates output tool_calls including __total
  - accumulates across multiple calls
  - handles missing keys gracefully
  - non-dict entry values are skipped

test_round_by_source:
  - rounds input tool_results dollars to 6 decimal places
  - rounds input tool_calls dollars to 6 decimal places
  - rounds output llm_text dollars
  - rounds output tool_calls dollars
  - handles missing sections gracefully

test_attribute_tokens:
  - with valid input/output sources and pricing
  - proportional distribution verified
  - empty tool_calls (no output tool_calls section)
  - total_chars==0 skips input attribution
  - output_tokens==0 skips output attribution
  - missing pricing (None)
```

**Group 2: File-I/O Functions (using tmp_path)**

```
test_parse_request_body:
  - valid JSON file returns dict
  - invalid JSON returns None
  - empty file returns None

test_write_request:
  - creates request_headers.txt with method+url, blank line, headers
  - api-key header is REDACTED
  - creates request.json for valid JSON body (pretty-printed)
  - creates request.json for non-JSON body (raw)
  - no request.json created if body is empty

test_write_response:
  - creates response_raw.txt with status+reason, headers, body
  - no file created if response is None (returns early)
  - empty body (no body section in output)

test_extract_usage:
  - SSE streaming: finds message_delta with usage fields
  - SSE streaming: takes last message_delta (multiple found)
  - non-streaming fallback: finds type==message with usage
  - filters to TOKEN_FIELDS only
  - merges timing data, computes duration_ms, removes timing.json
  - handles missing timing.json (no timing in output)
  - no usage found: prints warning, no usage.json created
  - skips directories without response_raw.txt

test_extract_prompts:
  - creates system_prompt.md by joining text blocks
  - creates first_user_message.md for first user message text
  - skips non-text system blocks
  - skips if system is absent
  - skips if messages is empty
  - skips if request.json missing or invalid
  - string content in user message (not a list) is not written

test_calculate_costs:
  - computes all 5 cost fields correctly
  - removes input_tokens etc. from top-level
  - adds model canonical name
  - skips if model absent
  - skips if model unknown (prints warning)
  - skips if usage.json absent
  - skips if request.json invalid

test_categorize_input_sources:
  - last user message = cache_write for tool_results
  - earlier user messages = cache_read for tool_results
  - second-to-last assistant message = cache_write for tool_calls
  - earlier assistant messages = cache_read for tool_calls
  - unknown tool_use_id = unknown tool name
  - read_file with mode=compress resolves correctly
  - total_chars = len(json.dumps(body))

test_extract_read_file_whitespace:
  - Read tool string content
  - read_file_compressed tool list content
  - non-read tool results are skipped
  - accumulates across multiple tool results

test_categorize_output_sources:
  - SSE: text blocks accumulated correctly
  - SSE: tool_use blocks accumulated, name resolved
  - SSE: invalid json in delta skipped
  - non-streaming fallback: text and tool_use blocks
  - empty file returns zeros

test_parse_response_content:
  - SSE returns list of text and tool_use blocks
  - SSE tool_use with invalid json input -> empty dict
  - non-streaming fallback message parsing
  - empty file returns []

test_export_parsed_response:
  - text blocks written as-is
  - tool_use blocks formatted with name(params)
  - returns False if no blocks
  - returns True on success

test_export_parsed_responses:
  - walks directory and calls export_parsed_response for each response_raw.txt

test_extract_file_ops:
  - Read tool result correctly attributed to file path
  - Write tool result correctly attributed
  - Edit tool uses new_string for chars
  - no file_path in input -> not tracked
  - file_size from os.path.getsize (or None if OSError)
  - list content in tool_result
  - tool_use_id not in tool_id_info is skipped

test_extract_source_attribution:
  - calls categorize_input_sources, categorize_output_sources, attribute_tokens
  - writes by_source and read_file_whitespace and file_ops to usage.json
  - skips if missing request.json or usage.json or response_raw.txt
  - skips if request body is None
```

**Group 3: mitmproxy-dependent functions**

```
test_redact_flow_files:
  - redacts x-api-key header in flow file
  - redacts authorization header
  - non-sensitive headers unchanged
  - no .flow files: returns without doing anything
  - FlowReadException causes skip with message
  - only modified files are rewritten (count reflects changes)

test_export_flows:
  - no .flow files: prints message and returns
  - vix agent: end_turn increments step, tool_use increments request
  - cc agent: system prompt hash change increments step
  - count_token URL is skipped
  - quota request is skipped
  - existing output dir is rmtree'd and recreated
  - FlowReadException causes skip
  - non-HTTPFlow objects in stream are skipped
  - timing.json written with request_start and response_end
  - request.json, request_headers.txt, response_raw.txt all written
```

**Group 4: summarize_usage**

```
test_summarize_usage:
  - single agent dir with numbered steps: creates usage.json
  - aggregates by_model and by_step correctly
  - _finalize_file_ops recomputes unique_files_read, total_read_chars etc.
  - _finalize_timing computes wall_clock_ms and avg_duration_ms
  - non-numbered subdirectories are skipped
  - dirs without numbered step subdirs are skipped
  - round_costs applied to all buckets
  - known agent (vix) gets AGENT_COLORS color
  - unknown agent gets hash-based color
  - deduplication of tool_ids across steps
```

### File Organization

The test file will be structured with:
1. Imports and fixtures at the top
2. Helper functions for building SSE content, flow files
3. Test classes grouped by function category (or flat functions with descriptive names)
4. Each test function is focused and tests one specific behavior

### Implementation Order

1. Pure logic tests first (no setup needed, fast to verify)
2. File I/O tests using `tmp_path`
3. mitmproxy flow tests using `tflow/treq/tresp` + `FlowWriter`
4. Integration-style tests for `summarize_usage`

### Achieving 80%+ Coverage

The functions with the most lines are `export_flows`, `summarize_usage`, `extract_source_attribution`, `categorize_output_sources`, `extract_file_ops`, and `attribute_tokens`. These must be tested with real scenarios. The key is to use real mitmproxy objects rather than mocking them, since the mitmproxy test utilities are available and work correctly.

Functions `main()` can be tested with a lightweight `monkeypatch` to replace `argparse.ArgumentParser.parse_args`, or it can be skipped since testing `main()` gives minimal coverage benefit relative to the functions it calls.

### Critical Files for Implementation

- `/workspace/export_flows.py` - The source file being tested; all tests derive from its behavior
- `/workspace/test_export_flows.py` - The test file to be created (does not exist yet)