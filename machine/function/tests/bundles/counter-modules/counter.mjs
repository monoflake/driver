// The counter fixture, counting the calls to increment for each key in its memory.
const counts = new Map();

export default {
	async fetch(request) {
		const [key, exported] = new URL(request.url).pathname.slice(1).split("/");
		if (request.method !== "POST" || exported !== "increment" || !key) {
			return new Response("no such export", { status: 404 });
		}
		const count = (counts.get(key) ?? 0) + 1;
		counts.set(key, count);
		return Response.json({ count: String(count) });
	},
};
