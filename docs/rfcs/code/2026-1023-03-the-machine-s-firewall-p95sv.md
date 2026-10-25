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

- **A deployment's `reaching` is fenced on the host, in two tables of the fence's own**, a small
  matter, provisional, chosen by the advisor on 2026-10-24, monoflake/platform's RFC y2xd3, the
  structure as monoflake/machine's module builds it. `table bridge fence` drops every frame between
  the ports of the containers' bridge but ARP, since filtering in the bridge family needs a table of
  that family, never this RFC's one `table inet filter`. `table inet fence` drops what a container
  sends the host unless it answers the host or matches an element of its set `reaching`, and drops
  every private destination a container's traffic is routed to, RFC 1918, the tailnet's shared
  address space of RFC 6598, link-local and ULA, and anything leaving by the tailnet.
  driver(machine) writes only `(reacher address, entry address, entry port)` elements into
  `reaching`, never a rule: a reacher reaches its targets through the machine's local entry, by
  name. The host side also closes what a container could send past its own namespace's rules, an
  IPv6 link-local address. Both tables stand beside NixOS's firewall until this RFC's table is
  built; the machine's change is applied before the driver change it serves, and reverts by itself
  unless confirmed.
- **A container holds no `CAP_NET_RAW`**, a small matter, provisional, chosen by the advisor on
  2026-10-24. It closes both spoofing a neighbor's source and sending a raw frame past the fence
  at once, and an image that truly needs raw sockets is a request to be made, not a default. A
  second set binding addresses to the bridge's ports stays unbuilt unless that request comes.
- **The fence keeps RFC 6598's shared space and anything leaving by `tailscale0` dropped**, a small
  matter, provisional, chosen by the advisor on 2026-10-24: a container must never reach another
  machine's trusted interface on the tailnet, and the driver's API port is the case in point.
- **One switch, one trial**, a small matter, provisional, chosen by the advisor on 2026-10-24: the
  NixOS firewall opening the entry's port on the containers' bridge is applied in the same switch
  as the fence, so it comes under the same trial and reverts with it.
- **The fence and a driver holding no `CAP_NET_RAW` go in one step**, a small matter, provisional,
  chosen by the advisor on 2026-10-24: an element matches by source address, and only a raw socket
  forges one, by ARP or by source, so no set binding a bridge port to its address is built. A
  container the driver cannot rebuild, which still holds `CAP_NET_RAW`, is deployed again through
  the normal path or removed before that step counts as done, the author choosing which for each.
- **A container on the local test machine is given a public nameserver**, a small matter,
  provisional, chosen by the advisor on 2026-10-24, as on a real machine, and the fence makes no
  exception for the local machine's own resolver.
- **A connection the fence allowed outlives its element**, a small matter, provisional, chosen by
  the advisor on 2026-10-24, and is not handled: an element goes only with its container, and the
  container's connections go with it.
- **The fence's unit is ordered as NixOS's own firewall is**, a small matter, provisional, chosen
  by the advisor on 2026-10-24, with no default dependencies, before the network.
- **The fence drops new forwarded connections leaving by the containers' bridge**, a small matter,
  provisional, chosen by the advisor on 2026-10-24, so a neighbor routing through the host never
  reaches a container's port; a container publishing a host port is named, never excepted on its
  own.
