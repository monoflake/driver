// The call a request came in with, held for that request so each store call carries its step,
// RFC 49qyg. The wrapped entry hands it the storage, since no extension module imports node.
const named = /^[0-9a-f]{16}$/;

let held;
let life;

// The request run with its call held, where it carries a well formed one.
function within(request, run) {
	const id = request.headers.get('call');
	if (held === undefined || id === null || !named.test(id)) {
		return run();
	}
	return held.run({ id, sequence: 0 }, run);
}

// The app's default export with its fetch run within its request's call, the first storage kept.
export function entered(handler, storage, calls) {
	if (held === undefined) {
		held = storage;
		life = calls.idLife;
	}
	if (typeof handler === 'function') {
		if (typeof handler.prototype?.fetch !== 'function') {
			return handler;
		}
		return class extends handler {
			fetch(request) {
				return within(request, () => super.fetch(request));
			}
		};
	}
	if (typeof handler?.fetch !== 'function') {
		return handler;
	}
	return {
		...handler,
		fetch: (request, env, context) => within(request, () => handler.fetch(request, env, context)),
	};
}

// A store call's input with its call's next step, never one the app gave, and none outside a call.
export function called(input, options) {
	const { call: given, ...rest } = input ?? {};
	const call = held?.getStore();
	if (call === undefined) {
		return rest;
	}
	call.sequence += 1;
	const expires = Number.parseInt(call.id.slice(0, 12), 16) + life;
	const last = options?.last === true;
	return { ...rest, call: { id: call.id, sequence: call.sequence, expires, last } };
}
