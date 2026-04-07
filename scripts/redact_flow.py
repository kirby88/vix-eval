"""Mitmproxy addon that redacts API keys from saved flows."""

from mitmproxy import http

_SENSITIVE_HEADERS = ("x-api-key", "authorization")


def response(flow: http.HTTPFlow):
    for header in _SENSITIVE_HEADERS:
        if header in flow.request.headers:
            flow.request.headers[header] = "[REDACTED]"
