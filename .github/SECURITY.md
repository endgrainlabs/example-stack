# Security

Report a vulnerability in any Endgrain Labs LLC repository to security@endgrainlabs.com, or through this repository's private vulnerability reporting under the Security tab. Include the repository, the version or commit, and steps to reproduce.

You will get an acknowledgement, and a fix or a written assessment; there is no service level. Please do not open a public issue for a vulnerability, and please give us a reasonable window before disclosing.

## Scope for this repository

Every credential in this stack is a published demo default, listed in the README, and the ingress is plain HTTP by design. Reporting either is not a vulnerability.

In scope: anything that makes the stack reach outside the cluster when the README says it does not, a script that does something to the host beyond what it documents, a pinned image or download that does not match its checksum or digest, and any way a request from outside the cluster can reach something the README says is not exposed.

Only the current `main` branch is supported.
