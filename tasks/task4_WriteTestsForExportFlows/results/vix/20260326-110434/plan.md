Now I have a thorough understanding of the codebase. Let me design a comprehensive test plan.

---

## Implementation Plan: Test Suite for `export_flows.py`

### Overview

The test file will be created at `/workspace/test_export_flows.py` (same directory as the source file, since the user's stated path `evaluation/usage/test_export_flows.py` does not exist and the actual file is at `/workspace/export_flows.py`).

The file has approximately 430 executable lines across 25 functions. To reach 80%+ coverage, we need to cover the pure-logic functions completely and exercise the main paths of the filesystem-heavy functions using `tmp_path` (pytest's built-in temporary directory fixture) and mitmproxy's own `tflow` test utilities.

---

### Function Inventory and Test Strategy

**Group 1: Pure logic, no I/O (test exhaustively with unit tests)**

1. `count_whitespace_stats(text)` — pure string analysis
2. `get_canonical_model(model_id)` — prefix matching against sorted list
3. `get_pricing(model_id)` — delegates to get_canonical_model
4. `sanitize_path(path)` — URL path sanitization
5. `format_headers(headers)` — header formatting with redaction
6. `extract_stop_reason(response_raw)` — SSE/JSON stop reason extraction
7. `_system_prompt_hash(body_json, agent_name)` — hash of system prompt entry
8. `_resolve_read_file_name(name, tool_input)` — mode-based name resolution
9. `_format_tool_params(input_data)` — compact parameter formatting
10. `_get_file_path(input_data)` — path extraction and absolutization
11. `_agent_color(name)` — deterministic hex color from name
12. `attribute_tokens(input_sources, output_sources, usage, pricing)` — token distribution math
13. `categorize_input_sources(body)` — cache position logic, pure dict processing
14. `extract_read_file_whitespace(body)` — tool result whitespace aggregation
15. `_aggregate_by_source(agg, flow_by_source)` — dictionary aggregation
16. `_round_by_source(agg)` — rounding dollar values in nested dict

**Group 2: File I/O functions (test with `tmp_path` fixture)**

17. `parse_request_body(request_path)` — reads JSON file
18. `write_request(flow, directory)` — writes request_headers.txt and request.json
19. `write_response(flow, directory)` — writes response_raw.txt
20. `extract_usage(directory)` — walks directory, creates usage.json
21. `extract_prompts(directory)` — walks directory, creates markdown files
22. `categorize_output_sources(response_path)` — reads response_raw.txt
23. `parse_response_content(response_path)` — reads and parses SSE/JSON
24. `export_parsed_response(response_path, output_path)` — reads and writes
25. `export_parsed_responses(directory)` — walks and writes
26. `calculate_costs(directory)` — reads/writes usage.json
27. `extract_file_ops(body, response_path)` — reads response, processes body
28. `extract_source_attribution(directory)` — orchestrates multiple reads/writes

**Group 3: mitmproxy-dependent functions (use `mitmproxy.test.tflow`)**

29. `redact_flow_files(directory)` — reads/writes .flow files
30. `export_flows(input_dir, output_dir)` — reads .flow files, creates directory tree

**Group 4: High-level aggregation (integration test with tmp_path)**

31. `summarize_usage(directory)` — complex aggregation of per-request usage.json files

---

### Detailed Test Cases

#### `count_whitespace_stats`
- Empty string: all zeros
- Single newline: `line_returns_count=1`
- Two consecutive spaces: `unnecessary_space_count=1`
- Three consecutive spaces: `unnecessary_space_count=2`
- Mixed: newlines plus multiple space runs
- No whitespace at all

#### `get_canonical_model` / `get_pricing`
- Exact match: `"claude-sonnet-4-5"` → itself
- With date suffix: `"claude-sonnet-4-5-20250101"` → `"claude-sonnet-4-5"`
- Longer prefix wins: `"claude-opus-4-5-..."` must match `"claude-opus-4-5"` not `"claude-opus-4"`
- Unknown model: `"gpt-4"` → `None`
- Empty string → `None`
- `get_pricing` returns the pricing dict for known; `None` for unknown

#### `sanitize_path`
- Path with query string: `/v1/messages?key=1` → `v1_messages`
- Leading/trailing slashes stripped
- Non-alphanumeric chars removed
- Long path truncated at 80 chars
- Empty path after stripping → empty string
- Path with special characters: spaces, dots, hyphens

#### `format_headers`
- Header with `x-api-key` → value becomes `[REDACTED]`
- Header with `authorization` → value becomes `[REDACTED]`
- Header with `content-type` → passes through unchanged
- Multiple headers: all lines joined with `\n`
- Case sensitivity: `X-API-KEY` (uppercase) must still be redacted (uses `.lower()` comparison)

#### `extract_stop_reason`
- SSE with `"type":"message_delta"` (no spaces) containing stop_reason
- SSE with `"type": "message_delta"` (with space) containing stop_reason
- SSE delta with null stop_reason (skipped), then valid one
- Non-streaming single JSON with `"type": "message"` and `stop_reason`
- Invalid JSON in data line (skipped gracefully)
- No relevant data → `"unknown"`
- SSE takes priority over non-streaming fallback

#### `_system_prompt_hash`
- cc agent (index 2): returns hash of 3rd system block
- vix agent (index 0): returns hash of 1st system block
- Unknown agent name (defaults to index 0)
- Missing `system` key → `None`
- Empty system list → `None`
- Index out of bounds → `None`
- Block with empty text → `None`
- Valid text block → 12-char hex string, deterministic

#### `_resolve_read_file_name`
- `"read_file"` with `{"mode": "compress"}` → `"read_file_compressed"`
- `"read_file"` with `{"mode": "original"}` → `"read_file_uncompressed"`
- `"read_file"` with `{}` (no mode) → `"read_file_uncompressed"`
- `"read_file"` with non-dict input → `"read_file_uncompressed"`
- `"bash"` → `"bash"` (passthrough)
- `"Read"` → `"Read"` (passthrough)

#### `_format_tool_params`
- Empty dict → empty string
- String value: `path="/foo"` format
- Non-string value: uses `json.dumps`
- Mixed string and non-string values
- Multiple params: comma-separated

#### `_get_file_path`
- `None` or non-dict input → `None`
- `{"file_path": "/abs/path"}` → returns as-is (already absolute)
- `{"path": "/abs/path"}` → returns as-is
- `{"file_path": "relative/path"}` → joined with `_PROJECT_ROOT`
- Empty dict → `None`
- Both keys present: `file_path` takes priority

#### `_agent_color`
- Known agents `"vix"` / `"cc"` use `AGENT_COLORS` (not `_agent_color`)
- Unknown name produces a valid `#rrggbb` hex string
- Same name always produces same color (deterministic)
- Different names produce different colors

#### `attribute_tokens`
- Full case: both input and output sources non-empty
- Zero `total_chars` → skips input attribution (no ZeroDivisionError)
- Zero `input_tokens` → skips input attribution
- `None` pricing → skips input attribution
- Zero `total_output_chars` → skips output attribution
- Zero `output_tokens` → skips output attribution
- Only tool results, no tool calls
- Only tool calls, no tool results
- Output with only llm_text (no tool calls)
- Output with only tool calls (no llm_text)
- Proportional math verified with exact numbers

#### `categorize_input_sources`
- Last user message content → `cache_write_chars`
- Earlier user messages → `cache_read_chars`
- Second-to-last message is assistant → tool calls there are `cache_write`
- Earlier assistant messages → tool calls there are `cache_read`
- `read_file` with `compress` mode resolves correctly
- No messages → returns empty dicts with `total_chars`
- String content (not list) in messages → skipped gracefully

#### `extract_read_file_whitespace`
- Tool result matching `read_file` tools accumulates whitespace
- Tool result for non-read tool (e.g., `bash`) is ignored
- `Read` (capitalized) tool name is also matched
- String content in tool result
- List content in tool result (joins text blocks)
- Unknown tool_use_id → ignored
- No messages → returns zeroed dict

#### `_aggregate_by_source`
- Empty flow_by_source → no change to agg
- Accumulates tool_results tokens/dollars/chars across calls
- Creates new keys when first seen
- Accumulates llm_text
- Accumulates tool_calls including `__total`
- Non-dict entry values are skipped

#### `_round_by_source`
- Rounds dollars to 6 decimal places in all sub-dicts
- Handles missing sections gracefully
- llm_text dollars rounded
- tool_calls dollars rounded

#### `parse_request_body`
- Valid JSON file → returns dict
- Invalid JSON file → returns `None`
- Non-existent file (no, this raises IOError — the function only catches JSON errors)
- Valid JSON file with nested objects

#### `write_request` / `write_response` (use `tmp_path` + `tflow`)
- Creates `request_headers.txt` with method + URL + headers
- Sensitive headers are redacted in header file
- Creates `request.json` with pretty-printed JSON body
- Raw body fallback when body is not valid JSON
- No body → no `request.json` created
- `write_response` with `None` response → returns early (no file)
- `write_response` with response body → includes body in output file

#### `extract_stop_reason` (covered above)

#### `parse_response_content` / `categorize_output_sources` (file I/O)
- SSE stream with text block → `[{"type": "text", "text": "..."}]`
- SSE stream with tool_use block → `[{"type": "tool_use", ...}]`
- SSE stream with invalid JSON in delta → falls back gracefully
- Non-streaming JSON fallback → parses message content
- Mixed content: text + tool_use in same response
- Empty file → returns `[]`
- `categorize_output_sources`: text chars counted; tool chars counted; read_file resolved

#### `export_parsed_response` / `export_parsed_responses`
- Empty blocks → returns `False`; no output file
- Text block → written as-is
- Tool use block → written as `[name(params)]`
- Multiple blocks concatenated

#### `extract_usage`
- SSE response with `message_delta` usage → creates `usage.json`
- Non-streaming fallback with `{"type": "message"}`
- Timing file present → merged into usage and timing.json removed
- Timing file absent → no timing key
- No usage found → prints warning, skips
- Only `TOKEN_FIELDS` preserved in output

#### `calculate_costs`
- Known model → computes all cost fields correctly
- Unknown model → prints warning, skips
- Missing model field → skips
- Invalid JSON request body → skips
- Top-level token keys removed after cost computation
- `model` key set to canonical name

#### `extract_file_ops`
- Read tool in assistant message + matching tool_result → per_file entry
- Write tool in response → per_file entry
- Edit tool in response → `new_string` chars counted
- Relative path → absolutized via `_PROJECT_ROOT`
- Multiple reads of same file → same entry, calls deduplicated by tool_id
- Non-read tools in assistant messages are ignored
- `file_size` populated if file exists, `None` if not

#### `redact_flow_files` (mitmproxy)
- No `.flow` files → returns without printing
- Flow without sensitive headers → not modified, count=0
- Flow with `x-api-key` header → redacted and rewritten
- Flow with `authorization` header → redacted
- `FlowReadException` on a file → prints skip message, continues

#### `export_flows` (mitmproxy integration)
- No `.flow` files in input_dir → prints message and returns
- Single flow, non-cc agent → step increments on `end_turn`
- Single flow, cc agent → step increments on system prompt change
- Flow with `/count_token` URL → skipped
- Flow with `"quota"` message → skipped
- Flow with `FlowReadException` → skips file, continues
- Existing output directory is removed and recreated
- Timing JSON written for each flow

#### `summarize_usage` (integration)
- Directory without numbered subdirs → skipped
- Agent dir with valid step/request structure → writes `usage.json` summary
- `by_model` bucketing works correctly
- `by_step` bucketing works correctly
- `_finalize_timing` computes wall_clock_ms from min/max timestamps
- `_finalize_timing` with zero request_count → avg=0
- `_finalize_file_ops` converts tool_ids to calls/chars

---

### Test File Organization

```
/workspace/test_export_flows.py

Sections:
1. Imports and shared fixtures (make_sse_response, make_nonstreaming_response, etc.)
2. TestCountWhitespaceStats
3. TestGetCanonicalModel
4. TestGetPricing
5. TestSanitizePath
6. TestFormatHeaders
7. TestExtractStopReason
8. TestSystemPromptHash
9. TestResolveReadFileName
10. TestFormatToolParams
11. TestGetFilePath
12. TestAgentColor
13. TestAttributeTokens
14. TestCategorizeInputSources
15. TestExtractReadFileWhitespace
16. TestAggregateBySource
17. TestRoundBySource
18. TestParseRequestBody
19. TestWriteRequest
20. TestWriteResponse
21. TestParseResponseContent
22. TestCategorizeOutputSources
23. TestExportParsedResponse
24. TestExportParsedResponses
25. TestExtractUsage
26. TestExtractPrompts
27. TestCalculateCosts
28. TestExtractFileOps
29. TestRedactFlowFiles
30. TestExportFlows
31. TestSummarizeUsage
```

### Key Implementation Notes

1. The file is at `/workspace/export_flows.py`, so the test file should be `/workspace/test_export_flows.py` and import with `import sys; sys.path.insert(0, '/workspace')` or just `import export_flows`.

2. For mitmproxy `HTTPFlow` objects, use `mitmproxy.test.tflow.tflow(resp=True)` which gives a real HTTPFlow with request and response, allowing `content` attribute setting.

3. For SSE response content, use a helper function `make_sse_response(events)` that builds the raw text with `data: {...}` lines.

4. For `format_headers`, the input must be a real `mitmproxy.net.http.Headers` or mock with `.fields` attribute returning a list of `(bytes, bytes)` tuples.

5. `_get_file_path` references `_PROJECT_ROOT` which is computed at module load time from `__file__`. Tests using relative paths will be joined to that root.

6. Use `pytest`'s `tmp_path` fixture for all file I/O tests (automatically cleaned up).

7. The `write_request` / `write_response` tests need real `HTTPFlow` objects since `flow.request.headers.fields` is a list of byte-tuples.

---

### Critical Files for Implementation

- `/workspace/export_flows.py` - Source file being tested; all test cases are derived from its logic
- `/workspace/test_export_flows.py` - The test file to be created (does not exist yet)

### Critical Files for Implementation
- `/workspace/export_flows.py` - Core logic to test; every function and branch drives a test case
- `/workspace/test_export_flows.py` - Test file to create with the full test suite