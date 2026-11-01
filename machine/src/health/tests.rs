use std::collections::BTreeMap;
use std::time::{SystemTime, UNIX_EPOCH};

use driver_machine_container::{Listed, Task};
use serde_json::json;

use driver_machine_management::{Hold as _, Tokens};

use super::{
	Answered, Deployment, Seen, differences, ids, live, settled, shown, unwritten, written,
};

fn read(rows: &[(Deployment, Seen)]) -> BTreeMap<Deployment, Seen> {
	rows.iter().cloned().collect()
}

fn making() -> Seen {
	Seen::Other("making".to_owned())
}

#[test]
fn a_deploy_in_flight_across_the_two_reads_is_left_out_of_the_baseline() {
	let first = read(&[
		((1, 1), Seen::Running),
		((1, 2), making()),
		((1, 3), Seen::Running),
		((1, 4), Seen::Stopped),
		((1, 5), Seen::Running),
	]);
	// The second made, the third stopped between the reads, the fifth deleted, a sixth deployed.
	let second = read(&[
		((1, 1), Seen::Running),
		((1, 2), Seen::Running),
		((1, 3), Seen::Stopped),
		((1, 4), Seen::Stopped),
		((1, 6), making()),
	]);
	let (baseline, flight) = settled(&first, &second);
	assert_eq!(baseline, read(&[((1, 1), Seen::Running), ((1, 4), Seen::Stopped)]));
	assert_eq!(flight, [(1, 2), (1, 3), (1, 5), (1, 6)]);
}

#[test]
fn a_state_making_or_failed_in_both_reads_is_not_judged() {
	let failed = Seen::Other("failed".to_owned());
	let both = read(&[((1, 1), making()), ((1, 2), failed)]);
	let (baseline, flight) = settled(&both, &both);
	assert!(baseline.is_empty());
	assert_eq!(flight.len(), 2);
}

#[test]
fn a_baseline_is_read_back_as_it_was_written() {
	let baseline = read(&[((1, 0x0a), Seen::Running), ((2, 0x0b), Seen::Stopped)]);
	assert_eq!(unwritten(&written(&baseline).to_string()).unwrap(), baseline);
}

#[test]
fn a_baseline_not_as_written_is_refused_and_a_later_state_passed_over() {
	assert!(unwritten("{").is_err());
	assert!(unwritten("{}").is_err());
	assert!(unwritten(r#"{"deployments":[{"id":1,"state":"running"}]}"#).is_err());
	let later = r#"{"deployments":[{"binding":1,"id":1,"state":"paused"}]}"#;
	assert!(unwritten(later).unwrap().is_empty());
}

#[test]
fn what_differs_from_the_baseline_is_named() {
	let baseline = read(&[((1, 0x0a), Seen::Running), ((1, 0x0b), Seen::Stopped)]);
	assert!(differences(&baseline, &baseline).is_empty());
	let now = read(&[((1, 0x0a), Seen::Absent), ((1, 0x0b), Seen::Running)]);
	assert_eq!(
		differences(&baseline, &now),
		[
			"deployment 0000000a of binding 1 was running and is absent",
			"deployment 0000000b of binding 1 was stopped and is running",
		]
	);
	// A deployment the baseline does not hold is no difference.
	let more = read(&[((1, 0x0a), Seen::Running), ((1, 0x0b), Seen::Stopped), ((1, 0x0c), making())]);
	assert!(differences(&baseline, &more).is_empty());
}

#[test]
fn an_answer_tells_its_state() {
	let told = |body| Seen::told(&Answered { status: 200, served: None, body });
	let state = |name| json!({"status": "success", "data": {"state": {"name": name}}});
	assert_eq!(told(state("running")), Seen::Running);
	assert_eq!(told(state("stopped")), Seen::Stopped);
	assert_eq!(told(state("making")), making());
	assert_eq!(told(json!({"status": "error", "reason": "not_found"})), Seen::Absent);
	assert_eq!(told(json!({"status": "error", "reason": "fault"})), Seen::Other("fault".to_owned()));
}

#[test]
fn a_deployment_is_one_id_however_many_containers_and_labels_hold_it() {
	let of = |labels: &[(&str, &str)]| Listed {
		id: "c".to_owned(),
		labels: labels.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect(),
		task: Some(Task::Running),
		binary: None,
	};
	let listed = [
		of(&[("driver.runs", "0000000a")]),
		of(&[("driver.runs", "0000000a")]),
		of(&[("driver.runs", "app/11")]),
		of(&[]),
	];
	assert_eq!(ids(&listed).into_iter().collect::<Vec<_>>(), [10, 11]);
}

#[test]
fn systemctl_show_is_read_by_its_fields() {
	let read = shown("NRestarts=3\nMainPID=42\nActiveState=activating\n");
	assert_eq!(read.active, "activating");
	assert_eq!(read.identity, ("42".to_owned(), "3".to_owned()));
}

#[test]
fn a_token_a_kept_list_forgot_is_not_live_and_another_of_its_binding_is() {
	let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
	let directory = std::env::temp_dir().join(format!("driver-health-{nanos}"));
	let lists = directory.join("state/lists");
	std::fs::create_dir_all(&lists).unwrap();
	let token = |character: &str| format!("1.{}A", character.repeat(42));
	let (old, new) = (directory.join("old"), directory.join("new"));
	std::fs::write(&old, format!("{}\n", token("B"))).unwrap();
	std::fs::write(&new, token("C")).unwrap();
	let mut tokens = Tokens::default();
	tokens.reload(std::slice::from_ref(&old));
	let forgotten = tokens.apply(1, Some(&[]));
	let hex: Vec<String> =
		forgotten.iter().map(|h| h.iter().map(|b| format!("{b:02x}")).collect()).collect();
	let list = json!({"namespace": "b00000001", "forgotten": hex});
	std::fs::write(lists.join("1.json"), list.to_string()).unwrap();
	let state = directory.join("state");
	assert!(live(std::slice::from_ref(&old), &state).is_empty());
	let held = live(&[old, new], &state);
	assert_eq!(held.get(&1), Some(&token("C")));
	std::fs::remove_dir_all(directory).unwrap();
}
