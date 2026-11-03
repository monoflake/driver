//! The protocol's call timing values as constants.

fn main() -> Result<(), String> {
	const SOURCE: &str = include_str!("../../../platform/model/protocol/calls.json");
	println!("cargo::rerun-if-changed=../../../platform/model/protocol/calls.json");
	let values: serde_json::Value = serde_json::from_str(SOURCE).map_err(|e| e.to_string())?;
	let mut rust = format!("#[cfg(test)]\nconst SOURCE: &str = {SOURCE:?};\n");
	for (key, name) in [
		("lockWait", "LOCK_WAIT"),
		("lockHold", "LOCK_HOLD"),
		("lookupDeadline", "LOOKUP_DEADLINE"),
		("idLife", "ID_LIFE"),
		("statusRetention", "STATUS_RETENTION"),
	] {
		let value = values
			.get(key)
			.and_then(serde_json::Value::as_u64)
			.ok_or_else(|| format!("{key} must be an unsigned integer"))?;
		rust.push_str(&format!(
			"/// The protocol's `{key}` in milliseconds.\npub const {name}: u64 = {value};\n"
		));
	}
	let out = std::env::var_os("OUT_DIR").ok_or("OUT_DIR is missing")?;
	std::fs::write(std::path::PathBuf::from(out).join("calls.rs"), rust).map_err(|e| e.to_string())
}
