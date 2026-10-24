/*** The variable install sets on a Worker, read beside the env its interface names. */

/** The install id, absent where install set none. */
type given = {@as("INSTALL_ID") installId?: string}

/** An env as the variable it may hold, read as possibly absent. */
external read: 'env => given = "%identity"
