/*** A secret of the Worker's env, which a Worker is given unset where none was put. */

/** A secret as given, absent where it was never put. */
external read: string => Nullable.t<string> = "%identity"
