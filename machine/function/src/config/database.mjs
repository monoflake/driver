// A database slot as a worker sees it, its calls posted to its binding's socket, RFC rt6gi.
export default function database(env) {
	const call = async (operation, input) => {
		const body = JSON.stringify({ interface: 'database', operation, input });
		const response = await env.socket.fetch(`http://database/database/${operation}`, {
			method: 'POST',
			headers: { 'content-type': 'application/json' },
			body,
		});
		const answer = await response.json();
		if (answer.status === 'success') {
			return answer.data;
		}
		throw new Error(`${answer.reason}: ${answer.message ?? 'the database refused it'}`);
	};
	return {
		execute: (input) => call('execute', input),
		// What became of a call's batches by its id, RFC 49qyg.
		status: (id) => call('status', { id }),
	};
}
