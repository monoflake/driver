/*** The variables install sets on a Worker, read beside the env its interface names. */

/** The install id and the kinds offered, each absent where install set none. */
type given = {@as("INSTALL_ID") installId?: string, @as("KINDS") kinds?: string}

/** An env as the variables it may hold, every one read as possibly absent. */
external read: 'env => given = "%identity"
