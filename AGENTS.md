# Documentation project instructions

## About this project

- This Mintlify site documents the public DoubleData Static ISP API.
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

- Document only the public bearer-token API under `/api/v1`.
- Never document network suppliers, upstream accounts, internal service keys, internal headers, internal identifiers, or administrator-only service endpoints.
- Never ask clients to send an idempotency key or organization ID.
- Keep operational failures customer-safe. Do not expose implementation details in errors or examples.
- Treat API keys and proxy credentials as secrets.
