---
name: 'What a Machine Makes of a List'
title: "How the machine driver makes and unmakes a binding's list, what bounds it, what each item's address is, where the list is kept, and when a binding is ended"
status: draft
supersedes: []
blocked-by: []
commits: []
references: []
---

## Question

Left open where `driver-machine` serves `management`, RFC 8c0rg. The contract, RFC vr5lw and
`model/contracts/kinds/management.res` with its samples, decides the list's bookkeeping: a list
sent whole by generation, an older one dropped and answered with the one held, an item named twice
or holding no credential or three `invalid`, a grace of at most a year, a week where none was set,
an item unasked kept until its grace has passed, `end` refusing what the list still asks. The
program does all of that. What it cannot do without deciding is what a machine makes of an item,
so an `apply` naming any item new or changed waits on this RFC, `todo!("4elqc")` in
`machine/src/listed.rs`, and is answered `fault` with that message.

Built provisionally for RFC n0o4l's second step, in monoflake/driver@cfdb8e31, and open to what running
shows. Items 1, 2, 5 and 8 are built as the Options propose, the bound counting a list's
`container` items alone against the machine's cores and memory, the qgroup made with the binding's
first container rather than its first item, and what an apply forgot of a binding's tokens kept in
its list's file. Of item 3 the `container` item alone is built, made at once at the address the
driver listens on, and the other three still wait on `todo!("4elqc")`. A deployment is kept by
containerd's labels as before, and a container whose task a reboot ended is started again when the
driver starts. Items 4, 6 and 7 stand as written.

The questions, each as it was asked:

1. **What bounds a list**, the `beyond_host` an `apply` answers before anything is held. vr5lw has
   a machine's bound a default its holder may raise or lower by how full the machine is, D8.
2. **What a binding is on the machine**: the containerd namespace its containers are in and the
   btrfs qgroup above its subvolumes, each a name `driver-machine-container`'s `Binding` holds as a
   string, made when its first item is made and removed when its last is.
3. **What each kind's item is, and its address**: a `container` item is a share of cores and
   memory the container kind reads from its `Binding`; a `volume` a subvolume, an `object` a bucket
   `driver-machine-object` opens at a directory and makes a subvolume of, and a `database` a SQLite
   file, the volume and the database without a block yet. A `made` item reports an address, and
   for none of the four is it written what the address names, nor which bucket an `object` call
   reaches, since it names none.
4. **How an item is unmade**, once its grace has passed or `end` asks it, and whether that waits
   for a call to come, as the program sweeps now, or a timer of its own.
5. **Where the list is kept**: the program holds every binding's list in memory, as
   `driver-machine-management` holds a token forgotten, so a restart answers generation 0 until
   the control sends its list again, while what was made stays on the machine unnamed.
6. **When a binding is ended**, so its tokens are forgotten, RFC 3d3nt: `end` takes an item's id,
   and nothing yet says which call ends the binding itself.
7. **The lists' lock**: `made` and `unmade` will block on btrfs and SQLite with every binding's
   list locked, found by the review of 2026-10-22.
8. **Tokens across a restart**: those an `apply` gives are held in memory alone and a restart
   forgets them, found by the review of 2026-10-22.

## Options

The agent's proposal, for the author to take, change or refuse.

- **Bound**: a list fits where its `container` items' cores and memory are at most the machine's,
  read by `driver-machine-management`'s usage, and its other items' sizes sum to at most the free
  space of the workloads' btrfs, `--mount`; a holder's own bound, D8, lowers it later.
- **Names**: a binding's namespace is `b<binding>` and its qgroup `1/<binding>`, the binding's
  integer in decimal, made on the first item and limited to what its items' sizes sum to.
- **Items**: a `container` item is recorded alone, `made` at once with the driver's own address,
  since the container kind applies its share as it creates each container; the other three wait
  for their kinds' blocks, answering `failed` with `beyond_host` until each is written.
- **A bucket** is a subvolume at `<mount>/buckets/<binding>/<item>`, made by
  `driver-machine-object`'s `Btrfs`, assigned to the binding's qgroup by the container kind's
  `Quota`, and opened with the item's size as its capacity. A binding holds one `object` item, the
  bucket every `object` call of its token reaches, and a second is `failed` with `beyond_host`
  until a call names its bucket.
- **Unmaking** runs on a timer of a minute beside the calls, so an item past its grace goes
  whether or not anything is asked.
- **Keeping**: the list is written to `<state>/lists/<binding>.json` on every change, read at
  start, so a restart neither forgets nor leaves anything unnamed.
- **Ending**: a binding is ended by a list of no items at a generation past every item's grace, so
  `end` stays an item's and the tokens are forgotten as its last item goes.
