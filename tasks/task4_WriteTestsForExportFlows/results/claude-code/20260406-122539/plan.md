# Plan: Write Tests for export_flows.py

## Context

The file `/workspace/export_flows.py` (1430 lines) is a mitmproxy-based data processing script that analyzes API flow files to extract token usage, costs, and metrics from Claude API interactions. There are currently no tests. The task is to write a comprehensive pytest suite at `/workspace/test_export_flows.py` achieving ≥80% code coverage.

## Critical Details

**File location**: `/workspace/export_flows.py` (not `evaluation/usage/`)
**Test file**: `/workspace/test_export_flows.py`

**Key constants**:
- `SYSTEM_PROMPT_INDEX = {"cc": 2, "vix": 0}` — cc uses index 2 (not 0)
- `_REDACTED_HEADERS = {b"x-api-key", b"authorization"}` — bytes, not strings
- `format_headers` expects `headers.fields` with byte tuples `(bytes_key, bytes_value)` and formats as `f"{k}: {v}"` (no decode needed since f-string handles bytes)
- `parse_request_body` catches `(json.JSONDecodeError, ValueError)` but NOT `FileNotFoundError` — missing file will raise, not return None

## mitmproxy Mock Strategy

Since `mitmproxy` is imported at module load time, patch `sys.modules` BEFORE importing `export_flows`:

```python
import sys
from unittest.mock import MagicMock

class _FakeFlowReadException(Exception):
    pass

_mock_io = MagicMock()
_mock_http = MagicMock()
_mock_exceptions = MagicMock()
_mock_exceptions.FlowReadException = _FakeFlowReadException

sys.modules["mitmproxy"] = MagicMock()
sys.modules["mitmproxy.io"] = _mock_io
sys.modules["mitmproxy.http"] = _mock_http
sys.modules["mitmproxy.exceptions"] = _mock_exceptions

import export_flows  # noqa: E402

# Patch the real FlowReadException so except clauses work
export_flows.FlowReadException = _FakeFlowReadException
```

For `isinstance(flow, HTTPFlow)` checks: use `MagicMock(spec=export_flows.HTTPFlow)` or set `mock_flow.__class__ = export_flows.HTTPFlow`. Best approach: create a simple real class and assign it as `export_flows.HTTPFlow`, then create instances of it.

## SSE Fixtures (module-level constants)

```python
SSE_END_TURN = '\n'.join([
    "200 OK", "", "",
    'data: {"type": "content_block_start", "index": 0, "content_block": {"type": "text"}}',
    'data: {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Hello world"}}',
    'data: {"type": "content_block_stop", "index": 0}',
    'data: {"type":"message_delta", "delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": 5}}',
])

SSE_TOOL_USE = ...  # Read tool with file_path input
SSE_WRITE_TOOL = ... # Write tool 
SSE_EDIT_TOOL = ... # Edit tool with new_string
SSE_NO_STOP = ...  # No message_delta line

NON_STREAMING = '{"type": "message", "stop_reason": "end_turn", "content": [{"type": "text", "text": "Hi"}], "usage": {"input_tokens": 10, "output_tokens": 3}}'
```

## Test Classes and Key Cases

### `TestCountWhitespaceStats`
- empty string → all zeros
- newlines counted correctly
- double/triple space runs → `len(run) - 1` each
- single spaces not counted
- total_chars == len(text)

### `TestGetCanonicalModel`
- exact match → itself
- with date suffix `claude-sonnet-4-6-20250514` → `claude-sonnet-4-6`
- longest prefix wins: `claude-opus-4-5-*` matches `claude-opus-4-5` not `claude-opus-4`
- unknown → None, empty → None

### `TestGetPricing`
- known model returns dict with all 4 keys
- date-suffixed model works
- unknown → None
- all MODEL_PRICING keys return non-None

### `TestSanitizePath`
- strips query string at `?`
- `/` → `_`, strip leading/trailing `_`
- removes special chars, keeps `-` and digits
- truncates at 80 chars
- empty string → empty string

### `TestSystemPromptHash`
- `{"cc": 2}` so index=2; body with 2 elements → None (index out of range)
- valid body with 3 system blocks where index 2 has text → 12-char hex
- empty system → None, empty text → None
- deterministic for same input
- unknown agent defaults to index 0

### `TestResolveReadFileName`
- `("read_file", {})` → `"read_file_uncompressed"`
- `("read_file", {"mode": "compress"})` → `"read_file_compressed"`
- `("read_file", None)` → `"read_file_uncompressed"` (non-dict)
- `("Read", {"mode": "compress"})` → `"Read"` (passthrough)

### `TestFormatToolParams`
- empty → `""`
- string value → `param="value"`
- non-string → `param=JSON`
- multiple keys → comma-separated

### `TestGetFilePath`
- non-dict → None
- `{"file_path": "/abs"}` → `/abs`
- `{"path": "/abs"}` → `/abs`
- relative path joined with `_PROJECT_ROOT`
- empty dict → None

### `TestAgentColor`
- returns `#RRGGBB` format
- deterministic for same name
- `"vix"` returns `"#7B2FBE"` (from AGENT_COLORS constant)

### `TestFormatHeaders`
- byte tuples `(b"content-type", b"application/json")`
- `b"x-api-key"` → `[REDACTED]`
- `b"Authorization"` (uppercase) → `[REDACTED]` (case-insensitive via `.lower()`)
- multiple headers joined by `\n`

### `TestParseRequestBody`
- valid JSON file → parsed dict
- invalid JSON → None (catches JSONDecodeError)
- empty file → None
- NOTE: missing file RAISES FileNotFoundError (document as known behavior)

### `TestExtractStopReason` (pure text, no I/O)
- SSE with `"type":"message_delta"` → stop_reason extracted
- SSE with spaced `"type": "message_delta"` → works too
- fallback non-streaming `"type": "message"` JSON → stop_reason extracted
- empty string → `"unknown"`
- malformed JSON lines skipped
- SSE takes priority over non-streaming

### `TestParseResponseContent` (tmp_path)
- SSE text block → `[{"type": "text", "text": "Hello world"}]`
- SSE tool_use → `{"type": "tool_use", "name": "Read", "input": {...}}`
- malformed partial_json → `input == {}`
- non-streaming message JSON → text block extracted
- no content → `[]`

### `TestCategorizeOutputSources` (tmp_path)
- text-only SSE → `{"llm_text": N, "tool_calls": {}}`
- tool_use SSE → tool_calls populated
- non-streaming → fallback parse
- empty → zeros

### `TestExtractReadFileWhitespace`
- no messages → all zeros
- Read tool result → whitespace counted
- non-Read tool result → ignored
- `read_file` with compress mode → counted as `read_file_compressed`
- list-format content → text concatenated

### `TestCategorizeInputSources`
- `total_chars == len(json.dumps(body))`
- last user message tool_result → `cache_write_chars`
- earlier tool_result → `cache_read_chars`
- second-to-last assistant tool_use → `cache_write_chars`
- unknown tool_id → labeled `"unknown"`

### `TestExtractFileOps` (tmp_path)
- Read tool → input tracking (unique_files_read, total_read_chars)
- Write tool → output tracking using `content` field
- Edit tool → output tracking using `new_string` field
- same file read twice → `calls == 2`
- missing file → `file_size == None`

### `TestAttributeTokens`
- zero total_chars → empty input
- proportional distribution of tokens by char count
- output tokens distributed by llm_text vs tool_call chars
- dollars = tokens * pricing_rate (rounded 6dp)
- pricing=None → skip input

### `TestAggregateBySource` and `TestRoundBySource`
- mutates agg with accumulated tokens/dollars/chars
- multiple flows summed
- rounds dollars to 6dp

### `TestExtractUsage` (tmp_path)
- SSE with message_delta usage → usage.json created
- non-streaming → usage extracted
- timing.json merged → duration_ms computed, timing.json deleted
- no usage → warning, no file created
- directories without response_raw.txt skipped

### `TestExtractPrompts` (tmp_path)
- system blocks extracted to `system_prompt.md`
- multiple text blocks joined with `\n\n`
- first user message to `first_user_message.md`
- invalid JSON → warning, skip
- content as string (not list) → no file

### `TestCalculateCosts` (tmp_path)
- costs computed from usage tokens + pricing
- canonical model stored in usage
- unknown model → skip
- raw token fields removed from top level
- missing files → skip

### `TestExportParsedResponse` (tmp_path)
- text block written as-is
- tool_use formatted as `[ToolName(params)]`
- empty blocks → returns False
- valid content → returns True
- `export_parsed_responses` walks directory, creates files

### `TestExtractSourceAttribution` (tmp_path)
- by_source, read_file_whitespace, file_ops added to usage.json
- missing files skipped
- unknown model → pricing=None, input by_source empty

### `TestSummarizeUsage` (tmp_path)
- agent directory with step subdirs → `usage.json` created
- request_count, costs aggregated
- by_model and by_step grouping
- timing: wall_clock_ms and avg_duration_ms
- by_source aggregated
- file_ops deduplicated by tool_ids
- directory without numbered subdirs skipped

### `TestWriteRequest` and `TestWriteResponse` (tmp_path + MagicMock)
- creates request_headers.txt with method + URL
- JSON body → pretty-printed request.json
- non-JSON body → raw fallback
- empty body → no request.json
- response None → early return
- response_raw.txt created with status line

### `TestExportFlows` (tmp_path + mock FlowReader)
Pattern: create `.flow` file, mock `FlowReader` to yield mock flows via `reader.stream()`.
- no flow files → prints message, returns
- `/count_token` URL → skipped
- quota message → skipped
- vix: end_turn → step incremented
- cc: system prompt hash change → step incremented
- existing output dir → shutil.rmtree + recreate
- FlowReadException → caught, continues
- timing.json created

### `TestRedactFlowFiles` (tmp_path + mock FlowReader/FlowWriter)
- no .flow files → returns
- flow with x-api-key → header redacted, file rewritten
- flow without sensitive headers → not rewritten
- FlowReadException → skip file, continue

### `TestMain`
- patch all 8 pipeline functions + argparse → all called once

## Running Tests

```bash
cd /workspace
pip install pytest pytest-cov mitmproxy
pytest test_export_flows.py -v --cov=export_flows --cov-report=term-missing
```

## Verification

Expected coverage: ≥80%. Key uncovered paths would be deep branches in step-boundary cc/vix logic and some error paths, but the test plan covers them explicitly.
