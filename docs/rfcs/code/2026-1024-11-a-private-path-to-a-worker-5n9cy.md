---
name: 'A Private Path to a Worker'
title: "How a Cloudflare binding's driver is reached over Cloudflare's private network, as a machine's is through its tunnel, in place of its public origin"
status: draft
supersedes: []
blocked-by: []
commits: []
references: []
---

## Question

The author decided on 2026-10-24 that a Cloudflare binding's driver is reached for now at its public
origin on the account's Workers subdomain: install binds on the Worker's behalf, reporting
that origin, and the control verifies it by calling the origin's management with the same binding
token, RFC nrs5v and monoflake/platform's record of the bind. The driver there is guarded by its
`BINDING` token alone. The author set the direction too: a Cloudflare binding should later be
reached over Cloudflare's private network, the way a machine is reached through its tunnel. A
Worker cannot sit behind a tunnel as an origin, so the way is not settled.

What to research, as questions:

- Can Cloudflare Access, with a service token, stand in front of the driver's route, so that a
  call without the token never reaches the Worker, and what does it ask of the bound account and of
  the control calling through it?
- Can the Worker reach the control over Workers VPC in the other direction, the control answering
  on a private address, and does that reverse which side opens the path?
- Can a custom hostname of Cloudflare for SaaS, which monoflake/cloud's RFC rxmd9 already names for
  crossing accounts, carry the driver's route privately between the two accounts?
- What does each cost on a free account, and which keeps "nothing runs on a timer across the two"?
