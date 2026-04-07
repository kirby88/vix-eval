# Plan: Write Tests for evaluation/usage/export_flows.py

## Context

The user wants a comprehensive pytest test suite for `/workspace/export_flows.py` placed at
`/workspace/evaluation/usage/test_export_flows.py`. The module is 1430 lines and processes
mitmproxy flow files — exporting them to per-flow directory structures with token usage,
cost calculations, and source attribution. The goal is ≥80% code coverage.

The `evaluation/usage/` directory does not yet exist and must be created.

---

## Files to Create

1. `/workspace/evaluation/usage/conftest.py` — mitmproxy stub injection + shared fixtures
2. `/workspace/evaluation/usage/test_export_flows.py` — full test suite

---

## Critical Design Decisions

### Import Strategy
The test file lives in `evaluation/usage/` but the module is at `/workspace/export_flows.py`.
`conftest.py` injects the path:
```python
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..'))
```

### Mitmproxy Mocking
`export_flows.py` imports from mitmproxy at module level. Since mitmproxy may not be
installed, `conftest.py` injects fake stub modules into `sys.modules` **before** any import
of `export_flows`. Tests then use `patch.object(ef, "FlowReader", ...)` to control flow
streams per-test, since `export_flows` binds the names locally via `from mitmproxy.io import`.

### File I/O
All filesystem tests use real `tmp_path` directories (not `mock_open`) because the functions
do `os.walk`, `glob.glob`, and multi-file operations that are too brittle to mock at the fd level.

---

## conftest.py Structure

```python
# Inject stubs before any import:
# - mitmproxy.io:         FlowReader (with .stream()), FlowWriter (with .add())
# - mitmproxy.exceptions: FlowReadException
# - mitmproxy.http:       HTTPFlow

# Session fixture `ef` returns the imported `export_flows` module.

# Helper classes: FakeHeaders, FakeRequest, FakeResponse
# Factory fixture `make_flow` creates mock HTTPFlow-like objects.
# Helper `write_flow_files(dirpath, ...)` writes request.json/usage.json/response_raw.txt.
```

---

## Test Classes and Key Cases

### TestCountWhitespaceStats
- Empty string → all zeros
- Single `\n` → line_returns=1
- `"  "` (2 spaces) → unnecessary_space_count=1
- `"   "` (3 spaces) → unnecessary_space_count=2
- Multiple runs accumulated
- total_chars matches `len(text)`

### TestGetCanonicalModel
- `"claude-opus-4-5-20250101"` → `"claude-opus-4-5"` NOT `"claude-opus-4"` (longest-prefix)
- `"claude-opus-4-20250101"` → `"claude-opus-4"`
- Unknown model → `None`
- Parametrize over all MODEL_PRICING keys (exact match)

### TestGetPricing
- Returns dict with input/cache_write/cache_read/output keys
- Model with date suffix resolved
- Unknown → `None`

### TestSanitizePath
- `/v1/messages` → `"v1_messages"` (strips leading `_`, replaces `/`)
- Query string stripped: `/path?foo=bar` → `"path"`
- Special chars removed: `"/v1/!messages@"` → `"v1_messages"`
- Truncated to 80 chars

### TestFormatHeaders
- `x-api-key` → `[REDACTED]`
- `authorization` → `[REDACTED]`
- Case-insensitive redaction (bytes lowered before comparison)
- Other headers preserved

### TestExtractStopReason
- SSE `"type":"message_delta"` (no space) with stop_reason
- SSE `"type": "message_delta"` (with space) with stop_reason
- SSE present but no stop_reason in delta → falls through to "unknown"
- Non-streaming JSON `"type":"message"` fallback
- No matching data → `"unknown"`
- Malformed JSON in SSE lines → skipped, continues

### TestSystemPromptHash
- cc uses index 2, vix uses index 0
- Index out of bounds → `None`
- Missing "system" key → `None`
- Empty text → `None`
- Returns 12-char hex string
- Deterministic: same text → same hash

### TestResolveReadFileName
- `read_file` + `{"mode": "compress"}` → `"read_file_compressed"`
- `read_file` + `{}` → `"read_file_uncompressed"`
- `read_file` + non-dict input → `"read_file_uncompressed"`
- Any other name → unchanged

### TestFormatToolParams
- String values quoted: `key="val"`
- Non-string JSON-dumped: `key=42`
- Empty dict → `""`

### TestGetFilePath
- Returns `file_path` key if present (absolute unchanged, relative made absolute)
- Falls back to `path` key
- `None` dict or missing keys → `None`

### TestParseRequestBody
- Valid JSON file → dict returned
- Invalid JSON → `None`
- FileNotFoundError is NOT caught (raises)

### TestWriteRequest / TestWriteResponse
- Creates `request_headers.txt` with METHOD URL line
- `x-api-key` redacted in headers
- Valid JSON body pretty-printed in `request.json`
- Invalid JSON body written raw
- Empty body → no `request.json` created
- `None` response → no `response_raw.txt` created

### TestExtractReadFileWhitespace
- `read_file` tool_result with string content → stats counted
- List content → concatenated then counted
- Non-read tools ignored
- Multiple reads accumulated

### TestCategorizeInputSources
- Last user message tool_result → `cache_write_chars > 0`
- Earlier user message tool_result → `cache_read_chars > 0`
- Second-to-last message (assistant) tool_use → `cache_write_chars > 0`
- Earlier assistant tool_use → `cache_read_chars > 0`
- `total_chars == len(json.dumps(body))`

### TestCategorizeOutputSources
- SSE `content_block_start/delta/stop` sequence for text → `llm_text` chars counted
- SSE tool_use block → `tool_calls[name]` chars counted
- Non-streaming fallback (no SSE data lines)
- `read_file` tool name resolved via `_resolve_read_file_name`

### TestParseResponseContent
- SSE text block assembled from deltas
- SSE tool_use block with JSON input assembled
- Invalid JSON in input_json_delta → empty dict fallback
- Non-streaming `{"type":"message","content":[...]}` fallback

### TestExportParsedResponse
- Returns `True` on success, `False` when no blocks
- Text blocks written as-is
- Tool use formatted as `[name(params)]`

### TestAttributeTokens
- Zero `total_chars` → empty input attribution
- Zero `output_tokens` → empty output attribution
- Proportional input: tool with 50% of chars gets ~50% of tokens
- Output has `__total` entry in tool_calls
- `None` pricing → empty input attribution

### TestAggregateBySource / TestRoundBySource
- Accumulates tokens, dollars, chars across calls
- Non-dict entries skipped
- Rounds dollars to 6 decimal places

### TestAgentColor
- Returns `#xxxxxx` format (7 chars)
- Deterministic for same name
- Different names → different colors

### TestRedactFlowFiles
- No `.flow` files → no-op
- Flow with `x-api-key` → header replaced with `[REDACTED]`, file rewritten
- Flow without sensitive headers → `modified=False`, file NOT rewritten
- `FlowReadException` → skipped
- Non-HTTPFlow objects processed without error

### TestExportFlows
- No `.flow` files → prints message, returns
- `/count_token` URL → flow skipped
- Quota message (content=="quota", no system) → flow skipped
- Quota with system present → NOT skipped
- cc agent: step increments when system prompt hash changes (prev_hash must be non-None)
- cc agent: first flow never increments step (prev_hash is None)
- vix agent: step increments after `end_turn` response
- vix agent: request_index increments for `tool_use` response
- `FlowReadException` → file skipped
- `None` response → timing.json still written (without response_end)
- Creates `{step}/{request}/` directory structure

### TestExtractUsage
- SSE `message_delta` usage extracted and written to `usage.json`
- Only TOKEN_FIELDS kept
- Timing merged from `timing.json`, which is then deleted
- Non-streaming fallback (`"type":"message"`)
- No usage found → warning printed, file not written

### TestExtractPrompts
- `system_prompt.md` written from text blocks
- `first_user_message.md` written from first user message
- Non-text system blocks skipped
- Invalid request.json → warning printed
- String content in user message → no file (only list content processed)

### TestCalculateCosts
- All cost fields computed: input, cache_write, cache_read, output, total
- Top-level token keys removed
- Canonical model name added
- Unknown model → warning, usage.json unchanged
- No model field → skipped

### TestExtractFileOps
- Read file tracked with file_path key
- Write file (Write/write_file) uses `content` for chars
- Edit file (Edit/edit_file) uses `new_string` for chars
- Deduplication: same file_path + same tool_id → counted once
- Same file_path + different tool_ids → calls=2
- Missing file → `file_size=None`

### TestSummarizeUsage
- Writes `usage.json` to agent directory
- `by_model` aggregated per model
- `by_step` aggregated per step directory
- Known agent (vix/cc) gets preset color from `AGENT_COLORS`
- Unknown agent gets MD5 color
- `timing.wall_clock_ms` = (max_response_end - min_request_start) * 1000
- `timing.avg_duration_ms` = total_duration_ms / request_count
- `file_ops.tool_ids` maps finalized to `calls`/`chars` (dedup)
- Dirs without numbered subdirectories skipped

---

## Coverage Exclusion
`main()` (~25 lines) is not tested — it's argparse scaffolding over functions already
tested individually. This keeps overall covered % well above 80%.

---

## Verification
Run: `cd /workspace && python -m pytest evaluation/usage/test_export_flows.py -v --tb=short`

With coverage: `python -m pytest evaluation/usage/test_export_flows.py --cov=export_flows --cov-report=term-missing`
