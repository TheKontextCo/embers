# Security policy

## Supported versions

Embers is currently an early developer preview. Security fixes are made on the
latest `main` branch and, once public releases exist, on the newest published
release. Older builds should not be assumed to receive fixes.

## Report a vulnerability privately

Do not open a public issue for a suspected vulnerability or include private
vault content, credentials, access tokens, or an exploit in public logs.

Use GitHub's **Report a vulnerability** form:

https://github.com/TheKontextCo/embers/security/advisories/new

Before public launch, a repository administrator must enable **Private
vulnerability reporting** under Settings → Security → Advanced Security. The
repository is not ready to accept external reports until that control is on.

Include the affected commit or version, macOS version and hardware, impact,
minimal reproduction, and any suggested mitigation. Use synthetic data and
redact user paths and provider credentials.

The maintainers will use the private advisory to clarify the report, assess
impact, coordinate a fix, and agree on disclosure timing. Please allow that
process to complete before publishing details.

## Security boundary

User-selected folder content and local snapshots are intended to remain on the
Mac. Network access belongs only to providers the user explicitly connects.
Reports involving unintended file access, credential exposure, sandbox escape,
signature or update-integrity failure, or undisclosed network transfer are in
scope.
