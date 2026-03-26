# Plan: Test Suite for export_flows.py

## Context

The user asked for tests for `evaluation/usage/export_flows.py`, but the file actually lives at `/workspace/export_flows.py` (there is no `evaluation/usage/` subdirectory). The test file will be created at `/workspace/test_export_flows.py` to match the source location.

The file (~1430 lines) is a standalone CLI tool that exports mitmproxy flow files into structured directories and computes token usage/cost analytics. It has no existing tests. Target: 80%+ coverage.

## Critical Files

- **Source**: `/workspace/export_flows.py`
- **Test file to create**: `/workspace/test_export_flows.py`

## Implementation Approach

Use `pytest` with:
- `tmp_path` fixture for all file/directory I/O
- `unittest.mock.patch` / `MagicMock` for mitmproxy (`FlowReader`, `FlowWriter`, `HTTPFlow`)
- Direct invocation of all public functions (no subprocess)

### Helper Utilities (top of test file)

```python
def make_flow_mock(url, method='POST', body=None, resp_body='',
                   status_code=200, req_headers=None, resp_headers=None,
                   ts_start=1000.0, ts_end=1005.0):
    """Returns a MagicMock whose __class__ is HTTPFlow (passes isinstance checks)."""
    flow = MagicMock()
    flow.__class__ = HTTPFlow
    flow.request.pretty_url = url
    flow.request.method = method
    flow.request.headers.fields = req_headers or []
    flow.request.get_text.return_value = body
    flow.request.timestamp_start = ts_start
    flow.response.status_code = status_code
    flow.response.reason = 'OK'
    flow.response.headers.fields = resp_headers or []
    flow.response.get_text.return_value = resp_body
    flow.response.timestamp_end = ts_end
    return flow

def sse_response(stop_reason='end_turn', text_blocks=None, tool_blocks=None, usage=None):
    """Build a synthetic SSE response string."""
    lines = []
    idx = 0
    for text in (text_blocks or []):
        lines += [
            f'data: {json.dumps({"type":"content_block_start","index":idx,"content_block":{"type":"text"}})}\n',
            f'data: {json.dumps({"type":"content_block_delta","index":idx,"delta":{"type":"text_delta","text":text}})}\n',
            f'data: {json.dumps({"type":"content_block_stop","index":idx})}\n',
        ]
        idx += 1
    for name, input_json in (tool_blocks or []):
        tool_id = f"t{idx}"
        lines += [
            f'data: {json.dumps({"type":"content_block_start","index":idx,"content_block":{"type":"tool_use","name":name,"id":tool_id}})}\n',
            f'data: {json.dumps({"type":"content_block_delta","index":idx,"delta":{"type":"input_json_delta","partial_json":input_json}})}\n',
            f'data: {json.dumps({"type":"content_block_stop","index":idx})}\n',
        ]
        idx += 1
    delta_payload = {"type": "message_delta", "delta": {"stop_reason": stop_reason}, "usage": usage or {}}
    lines.append(f'data: {json.dumps(delta_payload)}\n')
    return 'HTTP/1.1 200 OK\n\n' + ''.join(lines)
```

## Test Classes and Key Cases

### `TestCountWhitespaceStats` (pure)
- Empty string → all zeros
- Single `\n` → `line_returns_count=1`
- `"  "` (2 spaces) → `unnecessary_space_count=1`
- `"   "` (3 spaces) → `unnecessary_space_count=2` (len-1)
- Multiple separate space runs summed
- Single spaces between words → `unnecessary_space_count=0`
- `total_chars` = `len(text)` always

### `TestGetCanonicalModel` (pure)
- Exact match for each key in `MODEL_PRICING`
- With date suffix (e.g., `"claude-opus-4-5-20240101"` → `"claude-opus-4-5"`)
- Longer prefix matched before shorter: `"claude-opus-4-5-x"` → `"claude-opus-4-5"`, not `"claude-opus-4"`
- Unknown model → `None`
- Empty string → `None`

### `TestGetPricing` (pure)
- Known model with date suffix returns correct pricing dict
- Unknown model → `None`
- Pricing dict has keys: `input`, `cache_write`, `cache_read`, `output`

### `TestSanitizePath` (pure)
- Query string stripped
- `/` → `_`, leading/trailing `_` stripped
- Special chars removed (only `[a-zA-Z0-9_-]` kept)
- Truncated to 80 chars

### `TestFormatHeaders` (mock `headers.fields`)
- Normal header passes through as `"key: value"`
- `x-api-key` → `[REDACTED]` (case-insensitive)
- `authorization` → `[REDACTED]`
- Empty fields → `""`

### `TestExtractStopReason` (pure string)
- SSE `message_delta` with `stop_reason` → extracted
- Non-streaming JSON `{"type": "message", "stop_reason": "..."}` → extracted
- Neither → `"unknown"`
- Bad JSON in SSE line skipped
- Both compact (`"type":"message_delta"`) and spaced (`"type": "message_delta"`) forms recognized
- SSE returns first valid match (forward scan); non-streaming returns last valid match (reversed scan)

### `TestSystemPromptHash` (pure)
- `cc` agent → index 2; `vix` → index 0; unknown → index 0
- Returns 12-char hex matching `sha256(text.encode()).hexdigest()[:12]`
- Missing system / empty list / index OOB / empty text → `None`

### `TestResolveReadFileName` (pure)
- `read_file` + `mode=compress` → `"read_file_compressed"`
- `read_file` + `mode=original` / no mode / non-dict input → `"read_file_uncompressed"`
- Any other name → passthrough

### `TestFormatToolParams` (pure)
- String values quoted: `file_path="/foo"`
- Non-string values JSON-serialized: `count=42`, `flag=true`
- Multiple params comma-separated
- Empty dict → `""`

### `TestAggregateBySource` (pure, mutates agg)
- Aggregates `input.tool_results` and `input.tool_calls` (tokens/dollars/chars summed)
- Aggregates `output.llm_text` and `output.tool_calls`
- Creates new keys when absent; adds to existing keys
- Non-dict entries skipped gracefully
- Empty flow_by_source → agg unchanged

### `TestRoundBySource` (pure, mutates agg)
- Rounds dollars to 6 dp in all sections
- Does not change tokens or chars
- Empty agg → no error

### `TestAgentColor` (pure)
- Returns string matching `^#[0-9a-f]{6}$`
- Deterministic (same input → same output)
- Different names → different colors

### `TestAttributeTokens` (pure)
- Input tool_results/tool_calls distributed proportionally by chars/total_chars
- Output llm_text and tool_calls distributed proportionally
- `total_chars=0` or `input_tokens=0` or `pricing=None` → skip input attribution
- `total_output_chars=0` or `output_tokens=0` → skip output attribution
- Each result entry has `tokens`, `dollars`, `chars`
- `output.tool_calls.__total` is total tool chars fraction

### `TestExtractReadFileWhitespace` (pure, given body dict)
- `Read` and `read_file*` tools counted; others skipped
- String vs list `content` in tool_result handled
- Multiple results summed
- Non-list message content doesn't crash

### `TestCategorizeInputSources` (pure, given body dict)
- `total_chars = len(json.dumps(body))`
- Last user message → `cache_write_chars`; earlier → `cache_read_chars`
- `second_to_last_idx` assistant message → `cache_write` for tool_use blocks
- Tool name resolved via `_resolve_read_file_name`

### `TestCategorizeOutputSources` (file-based, `tmp_path`)
- SSE text block → `llm_text = len(text)`
- SSE tool_use block → `tool_calls[name] = len(json.dumps(full_block))`
- `read_file` with compress mode → key is `"read_file_compressed"`
- Non-streaming JSON fallback
- Empty file → `{"llm_text": 0, "tool_calls": {}}`

### `TestParseResponseContent` (file-based, `tmp_path`)
- SSE: text and tool_use blocks parsed and returned in order
- Delta accumulation across multiple `content_block_delta` events
- Bad JSON in `partial_json` → `input_data = {}`
- Non-streaming JSON fallback
- Empty → `[]`

### `TestExportParsedResponse` (file-based, `tmp_path`)
- Text block written as-is
- Tool use formatted as `\n[Name(params)]\n`
- Returns `True` on success, `False` for empty response
- Output file created only on success

### `TestExtractFileOps` (file-based, `tmp_path`)
- Read tools (`Read`, `read_file*`) tracked via tool_id
- Write tools (`Write`, `write_file`, `Edit`, `edit_file`) tracked from response
- `Edit`/`edit_file` use `new_string` for char count
- Same tool_id deduplicated (calls=1); different tool_ids for same file → calls=2
- Relative path resolved to absolute using `_PROJECT_ROOT`
- Non-existent file → `file_size=None`
- No `file_path`/`path` key → not tracked

### `TestParseRequestBody` (file-based, `tmp_path`)
- Valid JSON → dict returned
- Invalid JSON → `None`
- Missing file → `FileNotFoundError` raised

### `TestWriteRequest` (file-based, `tmp_path`, mock flow)
- Creates `request_headers.txt` with `METHOD URL` on first line
- Creates `request.json` with pretty-printed JSON body
- Invalid JSON body → raw fallback
- `None`/empty body → no `request.json` created
- `x-api-key` header → `[REDACTED]`
- `request.json` ends with `\n`

### `TestWriteResponse` (file-based, `tmp_path`, mock flow)
- Creates `response_raw.txt` with `STATUS REASON` on first line
- Body appended after blank line
- `flow.response = None` → no file created
- Headers redacted

### `TestExtractUsage` (file-based, `tmp_path`)
- SSE usage extracted and written to `usage.json`
- Non-streaming JSON fallback
- Extra token fields not in TOKEN_FIELDS filtered out
- `timing.json` merged into usage and then deleted
- `duration_ms = round((response_end - request_start) * 1000)`
- No usage found → no `usage.json`, warning printed
- Multiple flow dirs processed

### `TestExtractPrompts` (file-based, `tmp_path`)
- System prompt from text blocks written to `system_prompt.md`
- Multiple text blocks joined with `\n\n`
- Non-text system blocks excluded
- First user message text blocks written to `first_user_message.md`
- Non-list system or content → skipped gracefully
- Invalid `request.json` → warning printed

### `TestCalculateCosts` (file-based, `tmp_path`)
- Creates `usage["cost"]` with all 5 keys (`input`, `cache_write`, `cache_read`, `output`, `total`)
- Top-level token fields removed
- `canonical_model` written as `usage["model"]`
- Unknown model → warning, no cost added
- Missing model field → skipped
- Dollar amounts computed correctly from tokens × pricing rate

### `TestExtractSourceAttribution` (file-based, `tmp_path`)
- Adds `by_source`, `read_file_whitespace`, `file_ops` to `usage.json`
- Missing any of `request.json`, `usage.json`, `response_raw.txt` → dir skipped
- No model in body → `pricing=None`, input attribution empty

### `TestSummarizeUsage` (file-based, `tmp_path`)
- Writes `{agent_dir}/usage.json` with `title`, `color`, `by_model`, `by_step`, `by_source`, `read_file_whitespace`, `total`
- Known agents (`vix`, `cc`) use `AGENT_COLORS`; others use `_agent_color()`
- `request_count` totaled across all requests
- `by_model` aggregated by `usage["model"]` field
- `by_step` aggregated by step directory number
- `wall_clock_ms = round((max_response_end - min_request_start) * 1000)`
- `avg_duration_ms = round(total_duration / request_count)`
- Dirs without numbered step subdirs skipped
- File ops deduplicated by tool_id across requests

### `TestRedactFlowFiles` (mock FlowReader/FlowWriter)
- No `.flow` files → early return, prints `"Redacted API keys in 0 flow files"`
- HTTPFlow with `x-api-key` header → header set to `"[REDACTED]"`, file rewritten
- HTTPFlow with `authorization` header → same
- Non-HTTPFlow in stream → not modified
- `FlowReadException` → prints skip message, continues
- Unmodified flow → FlowWriter not called
- Count of modified files printed

### `TestExportFlows` (mock FlowReader/FlowWriter)
- No `.flow` files → prints "No *.flow files found", returns early
- Creates `{name}/{step}/{req}/` directories with `request_headers.txt`, `request.json`, `response_raw.txt`, `timing.json`
- `/count_token` URLs skipped
- `{"content": "quota"}` messages skipped
- `vix` mode: `end_turn` → increments step, resets req; other → increments req only
- `cc` mode: system prompt hash change → increments step; req always increments
- `FlowReadException` → skipped with message
- Existing output dir removed before re-export
- Non-HTTPFlow in stream → skipped

## Verification

After implementation, run:
```bash
cd /workspace
python -m pytest test_export_flows.py -v --tb=short
python -m pytest test_export_flows.py --cov=export_flows --cov-report=term-missing
```

Target: ≥80% line coverage. The `main()` function and `_PROJECT_ROOT` initialization are not tested (no logic beyond arg parsing and path joining).
