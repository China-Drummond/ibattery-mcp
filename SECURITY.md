# Security Policy

## Reporting a Vulnerability

Please **do not** open a public GitHub issue for security vulnerabilities.

Instead, use GitHub's private vulnerability reporting: go to the
[Security tab](../../security) of this repository and click **"Report a
vulnerability"**. This opens a private advisory visible only to you and the
maintainers, where you can describe the issue and, if applicable, propose a fix.

We'll acknowledge new reports as quickly as we can and keep you updated as we
work through the issue.

## Supported Versions

`ibattery-mcp` is pre-1.0 and does not yet have a formal long-term-support
policy. Security fixes are applied to the latest released version; please
make sure you're running the latest release before reporting an issue that
might already be fixed.

## Scope Notes

`ibattery-mcp` shells out to and links against external tools/libraries
(`libimobiledevice`) and runs a local, unauthenticated Unix-domain-socket IPC
channel between its two processes (`ibattery-mcp` and `ibattery-ble-helper`),
scoped to the current user's local filesystem permissions. If you find a way
to exploit this local IPC channel from another local user/process in a way
that shouldn't be possible, that's exactly the kind of report we want — please
report it privately as described above.