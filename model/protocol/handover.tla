---- MODULE handover ----
\* A binding keeps its database and object bucket across container crashes and redeploys.
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS Faults, OPEN_BEFORE_STOP, ACK_BEFORE_COMMIT, SERVE_BEFORE_STOP, NEVER_SERVE,
	OPEN_STALE_COPY
VARIABLES old, new, serving, request, storage, database, bucket, acked, crashes, steps,
	last, done
vars == <<old, new, serving, request, storage, database, bucket, acked, crashes,
	steps, last, done>>
kept == Cardinality(database) + Cardinality(bucket)
None == [steps |-> <<>>]

Init ==
	/\ old = "open"
	/\ new = "absent"
	/\ serving = "old"
	/\ request = "unasked"
	/\ storage = "none"
	/\ database = {}
	/\ bucket = {}
	/\ acked = 0
	/\ crashes = 0
	/\ steps = <<>>
	/\ last = None
	/\ done = FALSE

Write(target) ==
	/\ ~done /\ serving = "old" /\ old = "open" /\ request = "unasked"
	/\ request' = "pending"
	/\ storage' = target
	/\ steps' = Append(steps, "request:write")
	/\ UNCHANGED <<old, new, serving, database, bucket, acked, crashes, last, done>>

Commit ==
	/\ ~done /\ old = "open" /\ request = "pending"
	/\ request' = "committed"
	/\ database' = IF storage = "row" THEN {"request"} ELSE database
	/\ bucket' = IF storage = "object" THEN {"request"} ELSE bucket
	/\ steps' = Append(steps, "old:commit")
	/\ UNCHANGED <<old, new, serving, storage, acked, crashes, last, done>>

Ack ==
	/\ ~done /\ acked = 0
	/\ request = "committed" \/ (ACK_BEFORE_COMMIT /\ request = "pending")
	/\ acked' = 1
	/\ steps' = Append(steps, "request:ack")
	/\ UNCHANGED <<old, new, serving, request, storage, database, bucket, crashes, last, done>>

Start ==
	/\ ~done /\ new = "absent"
	/\ new' = "started"
	/\ steps' = Append(steps, "new:start")
	/\ UNCHANGED <<old, serving, request, storage, database, bucket, acked, crashes, last, done>>

Stop ==
	/\ ~done /\ old = "open"
	/\ old' = "stopped"
	/\ serving' = IF serving = "old" THEN "none" ELSE serving
	/\ request' = IF request \in {"unasked", "pending"} THEN "lost" ELSE request
	/\ steps' = Append(steps, "old:stop")
	/\ UNCHANGED <<new, storage, database, bucket, acked, crashes, last, done>>

OpenCopy(stale) ==
	/\ ~done /\ new = "started" /\ (old = "stopped" \/ OPEN_BEFORE_STOP)
	/\ ~stale \/ OPEN_STALE_COPY
	/\ new' = "open"
	/\ database' = IF stale THEN {} ELSE database
	/\ bucket' = IF stale THEN {} ELSE bucket
	/\ steps' = Append(steps, "new:open")
	/\ UNCHANGED <<old, serving, request, storage, acked, crashes, last, done>>

Open == \E stale \in BOOLEAN : OpenCopy(stale)

Serve ==
	/\ ~done /\ ~NEVER_SERVE /\ serving /= "new"
	/\ new = "open" \/ (SERVE_BEFORE_STOP /\ new = "started")
	/\ old = "stopped" \/ SERVE_BEFORE_STOP
	/\ serving' = "new"
	/\ steps' = Append(steps, "new:serve")
	/\ UNCHANGED <<old, new, request, storage, database, bucket, acked, crashes, last, done>>

Crash(actor) ==
	/\ ~done /\ crashes < Faults
	/\ IF actor = "old" THEN old = "open" ELSE new /= "absent"
	/\ old' = IF actor = "old" THEN "stopped" ELSE old
	/\ new' = IF actor = "new" THEN "absent" ELSE new
	/\ serving' = IF serving = actor THEN "none" ELSE serving
	/\ request' = IF actor = "old" /\ request \in {"unasked", "pending"}
		THEN "lost" ELSE request
	/\ crashes' = crashes + 1
	/\ steps' = Append(steps, "env:crash")
	/\ UNCHANGED <<storage, database, bucket, acked, last, done>>

\* Completion keeps the last run without adding a synthetic step.
Done ==
	/\ ~done /\ serving = "new" /\ request /= "pending"
	/\ (request = "committed" => acked = 1)
	/\ done' = TRUE
	/\ last' = [crashes |-> crashes, steps |-> steps,
		serving |-> serving, acked |-> acked, kept |-> kept]
	/\ UNCHANGED <<old, new, serving, request, storage, database, bucket, acked, crashes, steps>>

Next == (\E target \in {"row", "object"} : Write(target))
	\/ Commit \/ Ack \/ Start \/ Stop \/ Open \/ Serve
	\/ (\E actor \in {"old", "new"} : Crash(actor)) \/ Done
Spec == Init /\ [][Next]_vars /\ WF_vars(Stop) /\ WF_vars(Start)
	/\ WF_vars(Open) /\ WF_vars(Serve)

TypeOK ==
	/\ old \in {"open", "stopped"}
	/\ new \in {"absent", "started", "open"}
	/\ serving \in {"old", "new", "none"}
	/\ request \in {"unasked", "pending", "committed", "lost"}
	/\ storage \in {"none", "row", "object"}
	/\ database \subseteq {"request"} /\ bucket \subseteq {"request"}
	/\ kept \in 0..1 /\ acked \in 0..1 /\ crashes \in 0..Faults
	/\ done \in BOOLEAN
OneWriter == ~(old = "open" /\ new = "open")
AckedKept == acked <= kept
ServesAfterStop == serving = "new" => old = "stopped"
NewServes == <>[](serving = "new")

Line(s) ==
	LET f[i \in 0..Len(s)] == IF i = 0 THEN ""
		ELSE f[i - 1] \o (IF i = 1 THEN "" ELSE ",") \o s[i]
	IN f[Len(s)]
Runs ==
	\/ last = None
	\/ PrintT("run crashes=" \o ToString(last.crashes) \o " steps=" \o Line(last.steps)
		\o " serving=" \o last.serving \o " acked=" \o ToString(last.acked)
		\o " kept=" \o ToString(last.kept))
====
