// An answer of a body as it came, as a call's is.
export const answered = (body) =>
	new Response(body, { headers: { 'content-type': 'application/json' } });
