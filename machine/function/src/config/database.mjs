// A database slot as a worker sees it, its calls posted to its binding's socket, RFC rt6gi.
export default function database(env) {
	return {
		async execute(input) {
			const body = JSON.stringify({ interface: 'database', operation: 'execute', input });
			const response = await env.socket.fetch('http://database/database/execute', {
				method: 'POST',
				headers: { 'content-type': 'application/json' },
				body,
			});
			const answer = await response.json();
			if (answer.status === 'success') {
				return answer.data;
			}
			throw new Error(`${answer.reason}: ${answer.message ?? 'the database refused it'}`);
		},
	};
}
