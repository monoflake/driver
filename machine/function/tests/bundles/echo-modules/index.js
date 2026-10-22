// The echo fixture, answering each call to echo with the body it was sent.
import { answered } from "./lib/answer.js";

export default {
	async fetch(request) {
		const exported = new URL(request.url).pathname.slice(1);
		if (request.method !== "POST" || exported !== "echo") {
			return new Response("no such export", { status: 404 });
		}
		return answered(await request.text());
	},
};
