# Plan: Test Suite for export_flows.py

## Context
The file `/workspace/export_flows.py` (1430 lines) processes mitmproxy HTTP flow files into structured
output directories with token usage, cost calculations, and source attribution analytics. It has no
existing tests. The goal is a comprehensive pytest suite at `/workspace/test_export_flows.py` covering
≥80% of lines.

## Key functions to cover (grouped by testing strategy)

### Pure/Logic Functions (no I/O, test inline)
| Function | Test cases |
|---|---|
| `count_whitespace_stats` | empty, newlines, multi-spaces, both |
| `get_canonical_model` | date suffix stripped, no suffix, unknown, prefix order |
| `get_pricing` | known model, unknown model |
| `sanitize_path` | query params stripped, slashes replaced, invalid chars removed, 80-char truncation |
| `extract_stop_reason` | SSE message_delta, non-streaming JSON, missing → "unknown", bad JSON lines |
| `_system_prompt_hash` | valid body, no system, index OOB, empty text |
| `_resolve_read_file_name` | read_file+compress, read_file+original, read_file+no mode, other name |
| `extract_read_file_whitespace` | read_file result (str content), list content, non-read tool skipped |
| `categorize_input_sources` | tool results in last vs earlier messages, tool_calls in second-to-last |
| `_format_tool_params` | string/non-string values, empty dict |
| `attribute_tokens` | normal proportional, zero chars → skip input, zero output tokens |
| `_get_file_path` | file_path key, path key, non-dict, relative path → absolute |
| `_aggregate_by_source` | basic merge, missing keys, empty input |
| `_round_by_source` | rounds to 6 decimal places |
| `_agent_color` | deterministic hash-based hex color |

### File-based Functions (use `tmp_path` fixture, write real files)
| Function | Test cases |
|---|---|
| `parse_request_body` | valid JSON, invalid JSON → None |
| `format_headers` | sensitive headers redacted, others pass through |
| `write_request` | creates request_headers.txt + request.json, non-JSON body falls back |
| `write_response` | creates response_raw.txt, skip when response=None |
| `categorize_output_sources` | SSE streaming, non-streaming JSON fallback, empty file |
| `parse_response_content` | SSE text+tool_use blocks, non-streaming JSON, invalid JSON |
| `export_parsed_response` | text+tool blocks → formatted file, empty blocks → False |
| `export_parsed_responses` | walks dir, creates response_parsed.txt for each response_raw.txt |
| `extract_usage` | SSE message_delta, non-streaming JSON, no usage → warning, timing merge |
| `extract_prompts` | system prompt extracted, user message extracted, invalid JSON → warning |
| `calculate_costs` | known model → writes cost, unknown model → skipped |
| `extract_file_ops` | read ops from body history, write ops from response, missing file_size |
| `extract_source_attribution` | end-to-end: reads request+response+usage, writes enriched usage.json |
| `summarize_usage` | aggregates steps/models/sources, AGENT_COLORS vs hash fallback |

### Mitmproxy-mocked Functions
| Function | Test cases |
|---|---|
| `redact_flow_files` | no .flow files → no-op, modifies headers in-place, FlowReadException → skips |
| `export_flows` | no .flow files → prints message, cc step-boundary by prompt hash, vix step-boundary by end_turn, quota request skipped, count_token URL skipped |

## Critical files
- `/workspace/export_flows.py` — only file to be tested
- Test file to create: `/workspace/test_export_flows.py`

## Mocking strategy
- `mitmproxy.io.FlowReader`, `mitmproxy.io.FlowWriter`, `mitmproxy.http.HTTPFlow` — mock for redact/export tests
- `mitmproxy.exceptions.FlowReadException` — real class used for exception testing
- `tmp_path` (pytest built-in) — real filesystem for all file-based tests
- `unittest.mock.MagicMock` / `patch` — for HTTPFlow attributes (headers, request, response)

## Test file structure
```
test_export_flows.py
├── TestCountWhitespaceStats
├── TestGetCanonicalModel
├── TestGetPricing
├── TestSanitizePath
├── TestFormatHeaders
├── TestExtractStopReason
├── TestSystemPromptHash
├── TestResolveReadFileName
├── TestParseRequestBody
├── TestWriteRequest / TestWriteResponse
├── TestExtractReadFileWhitespace
├── TestCategorizeInputSources
├── TestCategorizeOutputSources
├── TestFormatToolParams
├── TestParseResponseContent
├── TestExportParsedResponse / TestExportParsedResponses
├── TestAttributeTokens
├── TestGetFilePath
├── TestExtractFileOps
├── TestExtractUsage
├── TestExtractPrompts
├── TestCalculateCosts
├── TestExtractSourceAttribution
├── TestAggregateBySource
├── TestRoundBySource
├── TestAgentColor
├── TestSummarizeUsage
├── TestRedactFlowFiles (mocked mitmproxy)
└── TestExportFlows (mocked mitmproxy)
```

## Verification
Run `pytest /workspace/test_export_flows.py -v --tb=short` and then:
```
pytest /workspace/test_export_flows.py --cov=export_flows --cov-report=term-missing
```
Target: ≥80% line coverage on `export_flows.py`.
