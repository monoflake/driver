// A bucket slot as a worker sees it, the storage product posted to its own socket, RFC ahcrp.
const encoder = new TextEncoder();

// Bytes as the envelope writes them in JSON, base64url unpadded.
function encoded(content) {
	const bytes =
		typeof content === 'string'
			? encoder.encode(content)
			: ArrayBuffer.isView(content)
				? new Uint8Array(content.buffer, content.byteOffset, content.byteLength)
				: new Uint8Array(content);
	let binary = '';
	for (let at = 0; at < bytes.length; at += 0x8000) {
		binary += String.fromCharCode(...bytes.subarray(at, at + 0x8000));
	}
	return btoa(binary).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
}

function decoded(text) {
	const binary = atob(text.replaceAll('-', '+').replaceAll('_', '/'));
	return Uint8Array.from(binary, (c) => c.charCodeAt(0));
}

// An input with what was not given left out, as the envelope omits an optional field.
function given(fields) {
	return Object.fromEntries(Object.entries(fields).filter(([, value]) => value !== undefined));
}

export default function bucket(env) {
	const call = async (operation, input) => {
		const response = await env.socket.fetch(`http://bucket/storage/${operation}`, {
			method: 'POST',
			headers: { 'content-type': 'application/json' },
			body: JSON.stringify(input),
		});
		const answer = await response.json();
		if (answer.status === 'success') {
			return answer.data;
		}
		throw new Error(`${answer.reason}: ${answer.message ?? 'the bucket refused it'}`);
	};
	return {
		write: (content, extension) =>
			call('object_write', given({ content: encoded(content), extension })),
		read: async (object, range) =>
			decoded((await call('object_read', given({ object, range }))).content),
		describe: (object) => call('object_describe', { object }),
		list: (after, limit) => call('object_list', given({ after, limit })),
		delete: (object) => call('object_delete', { object }),
	};
}
