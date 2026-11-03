// The database fixture, declaring the slot database and answering each call with its execute.
export default {
	async fetch(request, env) {
		const statements = [{ sql: await request.text() }];
		return Response.json(await env.database.execute({ statements }));
	},
};
