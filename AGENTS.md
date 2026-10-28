# Documentation project instructions

## About this project

- This Mintlify site documents the public DoubleData proxy products, public API, and Proxy SDK.
- Configuration lives in `docs.json` and the API contract lives in `openapi.json`.
- The public base URL is `https://app.proxy.doubledata.com/api/v1`.

## Terminology

- Use "Static ISP proxy" for the product and "rotation" for replacing selected IPs.
- Use "IP authorization" for the one source IP allowed on a subscription.
- Use "rotation unit" for one confirmed IP replacement.

## Style

- Use active voice and address the reader as "you".
- Keep sentences concise and headings in sentence case.
- Use code formatting for fields, paths, commands, status codes, and literal values.
- Treat all mutation examples as live production operations and place a warning before them.

## Content boundaries

- API reference pages document only the public bearer-token API under `/api/v1`.
- Keep Proxy SDK documentation under `sdk/`. Write concise integration documentation for application developers. Keep internal release preparation and legal-role analysis outside this public docs repository. Do not imply the Static ISP API enrolls devices or records SDK consent.
- SDK documentation may show public integration contracts and host-app examples. Never publish SDK implementation source, private build configuration, or unpublished service endpoints.
- Never document network suppliers, upstream accounts, internal service keys, internal headers, internal identifiers, or administrator-only service endpoints.
- Never ask clients to send an idempotency key or organization ID.
- Keep operational failures customer-safe. Do not expose implementation details in errors or examples.
- Treat API keys and proxy credentials as secrets.
