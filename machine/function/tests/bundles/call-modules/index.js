// The call fixture, a database call and a bucket write marked last, answering each one's step.
export default {
	async fetch(request, env) {
		const wait = Number(new URL(request.url).searchParams.get('wait'));
		const first = await env.records.execute({ statements: [] });
		await new Promise((resolve) => setTimeout(resolve, wait));
		const second = await env.images.write('hi', undefined, { last: true });
		return Response.json([first.call ?? null, second.call ?? null]);
	},
};
