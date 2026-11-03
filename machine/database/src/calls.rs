//! Call timing from the platform's protocol model, in milliseconds.

include!(concat!(env!("OUT_DIR"), "/calls.rs"));

#[test]
fn protocol_values_parse() {
	let values: serde_json::Value = serde_json::from_str(SOURCE).unwrap();
	for (key, value) in [
		("lockWait", LOCK_WAIT),
		("lockHold", LOCK_HOLD),
		("lookupDeadline", LOOKUP_DEADLINE),
		("idLife", ID_LIFE),
		("statusRetention", STATUS_RETENTION),
	] {
		assert_eq!(values[key].as_u64(), Some(value));
	}
}
