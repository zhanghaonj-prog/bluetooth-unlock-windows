# Security Policy

## Supported versions

The project is currently pre-release. Security fixes are provided only for the latest commit on the
default branch and the latest published `0.x` release, if one exists.

## Reporting a vulnerability

Do not open a public Issue for suspected credential disclosure, unauthorized unlock, pipe
impersonation, installer tampering, or a Credential Provider failure that can affect Windows sign-in.

Use the repository's **Security > Report a vulnerability** function to submit a private GitHub Security
Advisory. Include the affected commit or version, Windows version, reproduction steps, and the smallest
possible redacted log excerpt. Do not include passwords, DPAPI blobs, full SIDs, BLE addresses, SSIDs,
usernames, hostnames, registry exports, or crash dumps unless the maintainer explicitly requests a secure
transfer.

The maintainer should acknowledge a complete report within 7 days, provide an initial severity decision
within 14 days, and coordinate disclosure after a fix or mitigation is available.

## Security scope

High-impact reports include:

- disclosure of the stored Windows password;
- automatic unlock of a different user or Windows session;
- bypass of the one-use authorization or trusted Agent checks;
- unprivileged modification of Broker or Credential Provider trust configuration;
- a Provider/Broker failure that prevents normal Windows sign-in;
- compromise of official source or release artifacts.

BLE spoofing, RSSI variation, and the ability of a local administrator or SYSTEM process to decrypt a
DPAPI LocalMachine secret are documented design limitations, not security boundaries.
