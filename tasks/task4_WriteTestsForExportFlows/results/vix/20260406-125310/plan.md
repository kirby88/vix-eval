Looking at the codebase, the file is at `/workspace/export_flows.py` (not `evaluation/usage/export_flows.py`). The test file should be written at `/workspace/test_export_flows.py`. The mitmproxy environment is available via `/root/.local/pipx/venvs/mitmproxy/bin/python` with pytest, pytest-mock, and pytest-cov installed.

## Implementation Plan

### Overview

Write a comprehensive pytest test suite for `/workspace/export_flows.py` targeting 80%+ code coverage. The module has these function categories:

1. **Pure logic functions** (no I/O): `count_whitespace_stats`, `get_canonical_model`, `get_pricing`, `sanitize_path`, `format_headers`, `extract_stop_reason`, `_system_prompt_hash`, `_resolve_read_file_name`, `_format_tool_params`, `_get_file_path`, `_agent_color`, `_aggregate_by_source`, `_round_by_source`, `attribute_tokens`

2. **Filesystem I/O functions** (read/write files): `parse_request_body`, `write_request`, `write_response`, `extract_read_file_whitespace`, `categorize_input_sources`, `categorize_output_sources`, `extract_file_ops`, `export_parsed_response`

3. **Directory-walking functions**: `extract_usage`, `extract_prompts`, `calculate_costs`, `export_parsed_responses`, `extract_source_attribution`, `summarize_usage`

4. **Flow-file functions** (mitmproxy I/O): `redact_flow_files`, `export_flows`

### Strategy

- Use **real mitmproxy `tflow.tflow()`** for flow objects (they work and pass `isinstance` checks)
- Use **`tempfile.TemporaryDirectory`** for filesystem tests (no mocking needed for most)
- Use **`unittest.mock.patch`** only for `glob.glob` and `FlowReader` in flow-file tests
- Use **`pytest.capsys`** to suppress/capture print output
- Group tests into classes by function category

### Test File Structure

```
/workspace/test_export_flows.py
```

Organized as follows:

#### Class `TestCountWhitespaceStats`
- `test_empty_string`: empty input returns all zeros
- `test_no_extra_whitespace`: single line, no extra spaces
- `test_line_returns`: counts newlines
- `test_unnecessary_spaces`: counts runs of 2+ spaces (each run counts as len-1 extra)
- `test_mixed`: both newlines and extra spaces
- `test_single_spaces_not_counted`: single spaces not counted

#### Class `TestGetCanonicalModel`
- `test_exact_match`: model name exactly equals a key
- `test_with_date_suffix`: `claude-sonnet-4-5-20250101` -> `claude-sonnet-4-5`
- `test_longer_prefix_wins`: `claude-opus-4-5` vs `claude-opus-4` (longest prefix wins)
- `test_unknown_model`: returns `None`
- `test_empty_string`: returns `None`
- `test_all_known_models`: parameterized, each key returns itself

#### Class `TestGetPricing`
- `test_known_model`: returns correct pricing dict
- `test_with_suffix`: date-suffixed model resolves correctly
- `test_unknown_model`: returns `None`

#### Class `TestSanitizePath`
- `test_strips_query_string`: `?foo=bar` removed
- `test_slashes_to_underscores`
- `test_strips_leading_trailing_underscores`
- `test_removes_special_chars`
- `test_truncated_to_80_chars`
- `test_empty_path`

#### Class `TestFormatHeaders`
- `test_redacts_x_api_key`
- `test_redacts_authorization`
- `test_passes_through_normal_headers`
- `test_mixed_headers`: both sensitive and normal
- `test_empty_headers`

#### Class `TestExtractStopReason`
- `test_sse_end_turn`: parses `message_delta` with `end_turn`
- `test_sse_tool_use`: parses `message_delta` with `tool_use`
- `test_sse_skips_other_event_types`
- `test_sse_invalid_json_skipped`
- `test_non_streaming_fallback`: `{"type":"message","stop_reason":"end_turn",...}`
- `test_non_streaming_skips_non_message_type`
- `test_no_match_returns_unknown`
- `test_empty_string_returns_unknown`

#### Class `TestSystemPromptHash`
- `test_cc_uses_index_2`
- `test_vix_uses_index_0`
- `test_unknown_agent_uses_index_0`
- `test_no_system_returns_none`
- `test_index_out_of_range_returns_none`
- `test_empty_text_returns_none`
- `test_hash_is_12_chars`
- `test_different_texts_produce_different_hashes`

#### Class `TestResolveReadFileName`
- `test_read_file_compress_mode`
- `test_read_file_original_mode`
- `test_read_file_default_mode`
- `test_read_file_non_dict_input`
- `test_other_tool_names_passthrough`

#### Class `TestFormatToolParams`
- `test_string_value`
- `test_non_string_value`
- `test_mixed_types`
- `test_empty_dict`

#### Class `TestGetFilePath`
- `test_absolute_path_via_file_path_key`
- `test_absolute_path_via_path_key`
- `test_relative_path_becomes_absolute`
- `test_no_path_key_returns_none`
- `test_non_dict_returns_none`

#### Class `TestAgentColor`
- `test_deterministic_for_same_name`
- `test_different_names_produce_different_colors`
- `test_returns_hex_string`

#### Class `TestParseRequestBody`
- Use `tmp_path` fixture
- `test_valid_json`
- `test_invalid_json_returns_none`
- `test_empty_file_returns_none`

#### Class `TestWriteRequest`
- Use `tmp_path` fixture + real `tflow.tflow()`
- `test_creates_request_headers_txt`: check method+URL line present
- `test_redacts_api_key_in_headers`
- `test_creates_request_json_for_valid_json_body`
- `test_raw_body_when_not_json`
- `test_no_body_no_request_json`

#### Class `TestWriteResponse`
- `test_creates_response_raw_txt`: status code + reason present
- `test_with_body`
- `test_no_response_writes_nothing`

#### Class `TestExtractReadFileWhitespace`
- `test_read_file_tool_result_counted`
- `test_Read_tool_result_counted`
- `test_write_tool_results_ignored`
- `test_list_content_blocks_joined`
- `test_empty_messages`

#### Class `TestCategorizeInputSources`
- `test_last_user_message_is_cache_write`
- `test_earlier_user_messages_are_cache_read`
- `test_tool_calls_from_second_to_last_message`
- `test_no_messages`
- `test_total_chars_is_json_length`

#### Class `TestCategorizeOutputSources`
- Use `tmp_path` fixture with SSE content files
- `test_sse_text_block`
- `test_sse_tool_use_block`
- `test_sse_multiple_blocks`
- `test_non_streaming_fallback_text`
- `test_non_streaming_fallback_tool`
- `test_empty_file`

#### Class `TestAttributeTokens`
- `test_output_proportional_distribution`
- `test_input_proportional_distribution`
- `test_zero_total_chars_no_input_attribution`
- `test_zero_output_tokens_no_output_attribution`
- `test_empty_tool_results_and_calls`

#### Class `TestAggregateBySource`
- `test_accumulates_tokens`
- `test_accumulates_dollars`
- `test_adds_new_tools`
- `test_handles_empty_flow_by_source`

#### Class `TestRoundBySource`
- `test_rounds_input_tool_results_dollars`
- `test_rounds_output_llm_text_dollars`
- `test_rounds_output_tool_calls_dollars`

#### Class `TestParseResponseContent`
- Use `tmp_path` fixture
- `test_sse_text_block`
- `test_sse_tool_use_block_with_json`
- `test_sse_invalid_json_input_defaults_to_empty`
- `test_non_streaming_fallback`
- `test_empty_content`

#### Class `TestExportParsedResponse`
- Use `tmp_path` fixture
- `test_text_block_written`
- `test_tool_use_block_written`
- `test_returns_false_when_no_blocks`

#### Class `TestExtractFilePath` (already covered above as `TestGetFilePath`)

#### Class `TestExtractUsage`
- Use `tmp_path` fixture
- `test_extracts_from_sse_stream`
- `test_extracts_from_non_streaming`
- `test_merges_timing_and_removes_timing_file`
- `test_missing_usage_prints_warning`
- `test_skips_dirs_without_response_raw_txt`

#### Class `TestExtractPrompts`
- Use `tmp_path` fixture
- `test_writes_system_prompt_md`
- `test_writes_first_user_message_md`
- `test_skips_invalid_json`
- `test_handles_string_content_in_user_message`

#### Class `TestCalculateCosts`
- Use `tmp_path` fixture
- `test_calculates_correctly_for_known_model`
- `test_skips_unknown_model`
- `test_removes_raw_token_keys`
- `test_sets_canonical_model`

#### Class `TestRedactFlowFiles`
- Use `tmp_path` fixture with real `.flow` files
- `test_redacts_x_api_key`
- `test_redacts_authorization`
- `test_no_flow_files_does_nothing`
- `test_skips_non_http_flow` (use mock to inject non-HTTPFlow)

#### Class `TestExportFlows`
- Use `tmp_path` fixture with real `.flow` files
- `test_no_flow_files_prints_message`
- `test_creates_per_flow_directory`
- `test_skips_count_token_url`
- `test_skips_quota_messages`
- `test_vix_step_boundary_on_end_turn`
- `test_cc_step_boundary_on_system_prompt_change`
- `test_handles_flow_read_exception`

#### Class `TestExportParsedResponses`
- Use `tmp_path`
- `test_walks_directory_and_parses`

#### Class `TestExtractSourceAttribution`
- Use `tmp_path`
- `test_writes_by_source_to_usage_json`
- `test_skips_missing_files`

#### Class `TestSummarizeUsage`
- Use `tmp_path`
- `test_creates_summary_per_agent`
- `test_uses_known_agent_color`
- `test_uses_generated_color_for_unknown_agent`
- `test_skips_non_directory_entries`
- `test_skips_dirs_without_numbered_subdirs`

### Helper Utilities in Test File

```python
# Helper: build SSE response_raw.txt content
def make_sse_response(stop_reason="end_turn", usage=None, text="Hello", tool_calls=None):
    ...

# Helper: build a real .flow file
def make_flow_file(path, flows):
    ...

# Helper: create standard directory structure
def make_request_dir(base, step, req, body, response, usage=None, timing=None):
    ...
```

### Test Runner Configuration

Tests use `/root/.local/pipx/venvs/mitmproxy/bin/python -m pytest` since that is the environment with both mitmproxy and pytest. The conftest or pytest invocation will use `--import-mode=importlib` or add `/workspace` to `sys.path` so `import export_flows` works.

A `conftest.py` at `/workspace/conftest.py` is not needed; instead the test file uses `sys.path.insert(0, os.path.dirname(__file__))` at the top.

### Critical Design Decisions

1. **Use `tflow.tflow()`** from `mitmproxy.test.tflow` for real HTTPFlow objects that pass `isinstance(flow, HTTPFlow)` checks, rather than `MagicMock(spec=HTTPFlow)` which fails attribute access.

2. **Use `tmp_path` pytest fixture** (not `tempfile.TemporaryDirectory()`) for cleaner test code.

3. **For `redact_flow_files` and `export_flows`**, create real `.flow` files using `FlowWriter` rather than mocking `FlowReader`, since the binary format requires real serialization.

4. **For `export_flows` quota-check test**, inject a flow with body `{"messages": [{"role": "user", "content": "quota"}], "system": null}` (no system key, first message content = "quota").

5. **For `summarize_usage`**, test with a minimal but realistic directory tree: `{tmp}/{agent}/{step}/{req}/usage.json`.

6. **Coverage target**: The main risk areas for coverage gaps are the `summarize_usage` inner helper functions (`_finalize_file_ops`, `_finalize_timing`, `add_to_bucket`, `round_costs`, `empty_bucket`) — these need at least one integration test that exercises the full `summarize_usage` call.

### Critical Files for Implementation

- `/workspace/export_flows.py` - Source file being tested; all tests import from here
- `/workspace/test_export_flows.py` - The test file to create (does not exist yet)
- `/root/.local/pipx/venvs/mitmproxy/lib/python3.11/site-packages/mitmproxy/test/tflow.py` - Pattern for creating real HTTPFlow objects for testing