---
name: 'Who reaches a binding name'
title: "How the machine's entry admits an app by its binding name `{app}.b{binding}` only where the app declares it, while the gateway's domain and mount traffic and an app's own reaching still pass"
status: draft
supersedes: []
blocked-by: []
commits: []
references: []
---

## Question

Platform's RFC oomwh has an app declare its ingress in its release, beside its bindings: a direct
domain, a mount on the gateway, or the binding itself, the name `{app}.b{binding}`, given only when
declared. The control now keeps that declaration with the release and the deployment and hands it
to the driver as the optional `ingress` of `deployment-deploy`. The driver reads none of it yet.

The entry admits today by `allowed` in `machine/src/entry.rs`: a request from outside the
containers' subnet, from loopback, the tunnel or the tailnet, reaches any app by its name, and one
from inside is held to its source container's `reaching`, RFC y2xd3. So `{app}.b{binding}` answers
for every deployment, declared or not. Nothing is newly exposed by that meanwhile, since the entry
is reached only through a binding's private address.

What is open is how the entry refuses the binding name to a caller where the app did not declare it,
when the gateway carries an app's declared domain or mount to that same name. Seen from the entry,
the gateway's request and any other caller's come the same way, through the tunnel to loopback,
with the same `Host`.

Whatever answers it holds to these:

- **An app's reaching is kept.** A container reaching another by its `reaching` passes as now,
  declared or not, since that is a call inside the deployment and not ingress.
- **The gateway's traffic is admitted.** A request the gateway carries for a declared domain or a
  mount reaches the app though it did not declare the binding itself.
- **A trusted marker, not a header anyone can send.** `Host` and `X-Forwarded-Host` name what is
  asked, not who asks, so neither can tell the gateway from another caller.
- **The declaration survives a restart**, of the driver or the entry, as the deployment's labels
  do, since the entry reads containerd and not the control's state.
- **The entry still reads nothing of a request but its name**, platform's `entry` boundary, beyond
  the marker it checks.

## Options

The agent's view of the ways open, for the author to choose among or refuse. None is decided.

- **A listener of the gateway's own.** The entry listens on a second port reached only from the
  gateway's host reach, and admits there every deployment, while the first port admits a binding
  name only where it is declared. Trust is the network path, no secret is added, and it holds only
  as long as nothing else can reach that port.
- **A key the control hands the driver.** The control gives each driver a key with the deployment,
  the gateway's requests carry a header made from it, and the entry checks it before admitting an
  undeclared name. The gateway then needs the key, which today reads the control's state and holds
  no secret, so the key would be a secret of its own.
- **A signature the entry verifies.** The gateway signs each request with a private key and the
  entry checks it with a public key the control hands the driver, so the driver holds nothing that
  lets it make the gateway's requests. It costs a signature per request and the key's rotation.
- **No enforcement at the entry.** The binding name stays private to the binding's address, and
  "only when declared" means only that the platform publishes it, the deploy tool printing it, and
  never that the entry refuses it.

Whichever is taken, the driver reads `ingress` from the deployment, writes it into the labels the
entry reads for function and container deployments alike, and checks it in `allowed`.
