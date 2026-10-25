---
name: "The Machine's Firewall"
title: "A machine's firewall: nftables, its policy declared by the machine's module and its members written by the driver"
status: accepted
supersedes: []
blocked-by: []
commits: []
references: []
---

## Question

RFC vr5lw has a machine's driver keep its firewall in software: in, only at the driver's own port
and where a path compiled to the machine crosses the public network; out, only as each
deployment's `network` allows, RFC 49qyg. A machine runs NixOS's own firewall now, the tailnet's
interface trusted whole, SSH open on the public interface and a container's way out open to all.
How is the firewall built, how does it tell where a packet came from, and what of it does the
driver write.

## Decision

Decided by the author on 2026-10-23.

- **nftables, one table of the machine's own**, `table inet filter`, named for what it does as
  the workspace's `docs/naming.md` asks, in place of NixOS's firewall, since in nftables a drop in
  any base chain is final and an accept is not, so two tables could only narrow each other.
- **The policy is declared and the members are injected**: the machine's module declares the
  chains, the zones and every rule; the driver adds and removes only elements of the sets and maps
  those rules read, as the machine's containers come and go, never a rule.
- **A packet's zone is the interface it came in by**, checked by reverse path, `fib saddr . iif oif
  missing drop`, so an address forged on the public interface is dropped: loopback, the public
  interface, a provider's private interface where there is one, the tailnet's, and the containers'
  bridges.
- **Nothing comes in from the public network**, SSH included: a machine is reached through the
  tailnet alone, the provider's own firewall left as it is. A machine is still reached through its
  provider's console when the tailnet is down.
- **A container goes out only where its deployment's `network` allows**, a map from its address to
  what it may reach, written by the driver as it deploys and removed as it deletes.
- **A firewall changed on a machine reached remotely is tried before it is kept**: activated
  without becoming the boot default, and rolled back on its own unless the tailnet is confirmed
  still to reach the machine within minutes.
- **Built once the fourth thread has returned the test machines**, before the platform keeps data.
- **Three points are settled as it is built, provisionally, and written here then**: whether
  Tailscale keeps writing its own rules beside the table or the table holds the one it needs, its
  addresses dropped from any other interface; whether the bridge plugin's masquerade stays the
  plugin's or moves into the table; how a deployment's `network` is written as addresses and ports
  on a machine.

### Ledger

Choices made provisionally while the thread runs, read by the author at its end.

- **A deployment's `reaching` is fenced on the host, in this table**, a small matter, provisional,
  chosen by the advisor on 2026-10-24, monoflake/platform's RFC y2xd3. The machine's module writes
  the base rules: forwarding across the containers' bridge, and every private destination, RFC
  1918, ULA and link-local, dropped unless an allowed element matches, filtered in the bridge
  family. driver(machine) writes only `(reacher, target, port)` elements, never a rule, as this
  RFC has it; the per-container iptables of the first try was the departure. The host side also
  closes what a container could send past its own namespace's rules, a raw frame or an IPv6
  link-local address. The machine's change is applied before the driver change it serves.
