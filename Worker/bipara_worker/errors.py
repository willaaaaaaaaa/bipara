"""Typed errors shared by worker modules."""

from __future__ import annotations

from enum import StrEnum


class ValidationFailure(StrEnum):
    MISSING_CONTENT = "missing_content"
    INVALID_JSON = "invalid_json"
    TRANSLATION_SHAPE = "translation_shape"
    UNIT_MISMATCH = "unit_mismatch"
    INVALID_TRANSLATION_TEXT = "invalid_translation_text"
    OUTPUT_TOO_LARGE = "output_too_large"
    ALIGNMENT_SHAPE = "alignment_shape"


# Keep in sync with GatewayError. Compatible endpoints can put arbitrary
# strings in error.code, so a character/length check alone is insufficient.
_PROVIDER_CODES = frozenset({
    "401", "1000", "1001", "1003", "1005", "1113", "1200",
    "1210", "1211", "1212", "1213", "1214", "1215",
    "1220", "1221", "1222", "1230", "1234", "1261",
    "1301", "1302", "1305", "1308", "1309", "1310", "1311", "1313",
    "1314", "1315", "1316", "1317", "1318", "1319", "1320", "1321",
    "invalid_api_key", "model_not_found", "context_length_exceeded",
    "invalid_request_error", "insufficient_quota", "rate_limit_exceeded",
    "credit_balance_exhausted", "organization_spend_limit_exceeded",
    "project_spend_limit_exceeded", "organization_usage_limit_exceeded",
    "slow_down", "server_is_overloaded",
})


class WorkerError(Exception):
    """A normalized per-request failure with a protocol error code.

    ``retry_after_ms`` is None or an integer in [0, 3600000] milliseconds.
    """

    def __init__(
        self,
        code: str,
        retry_after_ms: int | None = None,
        *,
        http_status: int | None = None,
        provider_code: object = None,
        validation_reason: ValidationFailure | None = None,
    ) -> None:
        super().__init__(code)
        self.code = code
        self.retry_after_ms = retry_after_ms
        self.http_status = http_status if type(http_status) is int and 300 <= http_status <= 599 else None
        if type(provider_code) is int and 100 <= provider_code <= 9999:
            provider_code = str(provider_code)
        self.provider_code = provider_code if isinstance(provider_code, str) and provider_code in _PROVIDER_CODES else None
        self.validation_reason = validation_reason if isinstance(validation_reason, ValidationFailure) else None

    def __repr__(self) -> str:  # pragma: no cover - diagnostic only
        return f"WorkerError(code={self.code!r}, retry_after_ms={self.retry_after_ms!r})"
