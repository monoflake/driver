---
name: 'What Objects Leave a Machine'
title: "What the `object` contract leaves a machine's bucket to answer: a page of no names, a page past a thousand, which strings are names, and what a capacity counts"
status: draft
supersedes: []
blocked-by: []
commits: []
references: []
---

## Question

Left open where `driver-machine-object` serves the `object` interface, RFC vr5lw and
`model/contracts/kinds/objects.res` with its samples. A bucket is a btrfs subvolume holding an
SQLite index of its objects by name and each content once, as a file named by its BLAKE3, decided
by the author on 2026-10-22. Every sample holds. What the contract does not say:

1. **A list whose `limit` is 0.** It asks for no names, and `next`, "the name to list after",
   cannot say where the next page begins when nothing was listed and no `after` was given, since no
   name is before every name. It waits on this RFC, `todo!("lnxbp")` in
   `machine/object/src/bucket.rs`, and is answered `fault`.
2. **A `limit` past a thousand.** The contract has a thousand unless set, and says nothing of a
   most. The bucket answers at most a thousand, `PAGE`, with `next` set, which the contract's "at
   most `limit`" allows.
3. **Which strings are names.** The contract writes a name as a string and bounds nothing of it. The
   bucket holds any, the empty one and one holding NUL among them, sorted by their UTF-8 bytes, and
   bounded only by the body a call may send.
4. **What a capacity counts**, the `given` size a case starts with. The bucket counts each content
   once, however many names hold it, and not its index; the qgroup above its subvolume, the list's,
   RFC 4elqc, holds the rest.

## Options

The agent's proposal, for the author to take, change or refuse.

- **A `limit` of 0 is `malformed`**, and the contract writes `limit` as 1 to a thousand, so a page
  always says where the next begins.
- **A thousand is the most a page holds**, written in the contract beside the default, as S3's
  `max-keys` is.
- **A name is 1 to 1024 bytes of UTF-8**, as S3's key, the contract's `bounds` holding it and a
  name past it `malformed`, so the S3 bridge can name every object and none is empty.
- **A capacity counts content once**, as the bucket does, since deduplication is the bucket's own
  and what a caller is charged for is what it holds.
