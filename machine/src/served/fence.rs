//! The driver's share of the machine's `reaching` set, each element whose reacher is in its subnet,
//! written again at start and each [`PERIOD`] as a boot or a firewall revert resets it, RFC p95sv.

use std::collections::BTreeSet;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

use driver_machine_container::{Containerd as _, Listed, Task};
use serde_json::Value;

use crate::Driver;
use crate::entry::{ADDRESS, REACHING, RUNS, Subnet, subnet};

/// How often the set is written again.
pub(super) const PERIOD: Duration = Duration::from_secs(60);

/// The set, by its table's family and name and its own, as the bridge writes one element of it.
const FENCE: [&str; 3] = ["inet", "fence", "reaching"];

/// One element, a reacher's address, the entry's and the entry's port.
type Element = (Ipv4Addr, Ipv4Addr, u16);

/// The entry a container was attached with, as the bridge answered it when it was made.
const ENTRY: &str = "driver.entry";

/// What the set should hold, an element for each running container of a deployment reaching
/// others, at its own address and the entry its labels hold.
pub(super) fn wanted(listed: &[Listed]) -> BTreeSet<Element> {
	listed
		.iter()
		.filter(|l| l.task == Some(Task::Running) && l.labels.contains_key(RUNS))
		.filter(|l| l.labels.get(REACHING).is_some_and(|r| !r.is_empty()))
		.filter_map(|l| {
			let at = l.labels.get(ADDRESS)?.parse::<SocketAddr>().ok()?;
			let SocketAddr::V4(entry) = l.labels.get(ENTRY)?.parse::<SocketAddr>().ok()? else {
				return None;
			};
			match at.ip() {
				std::net::IpAddr::V4(ip) => Some((ip, *entry.ip(), entry.port())),
				std::net::IpAddr::V6(_) => None,
			}
		})
		.collect()
}

/// What `nft -j list set` says the set holds, its elements bare or each with its own options.
pub(super) fn held(listed: &Value) -> Option<BTreeSet<Element>> {
	let set = listed.get("nftables")?.as_array()?.iter().find_map(|o| o.get("set"))?;
	let Some(elements) = set.get("elem").and_then(Value::as_array) else {
		return Some(BTreeSet::new());
	};
	elements
		.iter()
		.map(|e| {
			let concat = e.get("concat").or_else(|| e.get("elem")?.get("val")?.get("concat"))?;
			let [reacher, entry, port] = concat.as_array()?.as_slice() else { return None };
			let port = u16::try_from(port.as_u64()?).ok()?;
			Some((reacher.as_str()?.parse().ok()?, entry.as_str()?.parse().ok()?, port))
		})
		.collect()
}

/// The `nft` arguments adding or deleting the elements given, none where there are none.
pub(super) fn written(verb: &str, elements: &BTreeSet<Element>) -> Option<Vec<String>> {
	if elements.is_empty() {
		return None;
	}
	let each: Vec<String> = elements.iter().map(|(r, e, p)| format!("{r} . {e} . {p}")).collect();
	let [family, table, set] = FENCE;
	let listed = format!("{{ {} }}", each.join(", "));
	Some([verb, "element", family, table, set, &listed].map(str::to_owned).to_vec())
}

async fn nft(args: &[String]) -> Result<String, String> {
	let output = tokio::process::Command::new("nft")
		.args(args)
		.output()
		.await
		.map_err(|e| format!("nft {}: {e}", args.join(" ")))?;
	match output.status.success() {
		true => Ok(String::from_utf8_lossy(&output.stdout).into_owned()),
		false => {
			Err(format!("nft {}: {}", args.join(" "), String::from_utf8_lossy(&output.stderr).trim()))
		}
	}
}

/// The elements whose reacher lies in `subnet`, the driver's own, every other another driver's.
pub(super) fn ours(elements: &BTreeSet<Element>, subnet: Subnet) -> BTreeSet<Element> {
	elements.iter().filter(|(reacher, ..)| subnet.holds(IpAddr::V4(*reacher))).copied().collect()
}

/// The elements of the driver's own subnet wanted and not held.
pub(super) fn missing(
	held: &BTreeSet<Element>,
	wanted: &BTreeSet<Element>,
	subnet: Subnet,
) -> BTreeSet<Element> {
	ours(wanted, subnet).difference(held).copied().collect()
}

/// One `nft` delete for each element of the driver's own subnet held and not wanted, so one
/// already gone keeps none back.
pub(super) fn deletes(
	held: &BTreeSet<Element>,
	wanted: &BTreeSet<Element>,
	subnet: Subnet,
) -> Vec<Vec<String>> {
	let dead = ours(held, subnet);
	dead.difference(wanted).filter_map(|d| written("delete", &BTreeSet::from([*d]))).collect()
}

/// Whether `nft` failed for an element already gone, which is what a delete wants.
pub(super) fn gone(why: &str) -> bool {
	why.contains("No such file")
}

/// The set as `nft` lists it now.
async fn listed_set() -> Result<BTreeSet<Element>, String> {
	let [family, table, set] = FENCE.map(str::to_owned);
	let text = nft(&["-j".into(), "list".into(), "set".into(), family, table, set]).await?;
	let value: Value = serde_json::from_str(&text).map_err(|e| format!("nft's listing: {e}"))?;
	held(&value).ok_or_else(|| "nft's listing holds no set as expected".to_owned())
}

/// What the set should hold now, from every running container of every binding the driver holds.
async fn running(driver: &Driver) -> Result<BTreeSet<Element>, String> {
	let made: Vec<_> = driver.lists.lock().await.values().filter_map(|l| l.made.clone()).collect();
	let mut all = BTreeSet::new();
	for binding in made {
		let listed =
			driver.functions.containers.containerd.list(&binding.namespace).await.map_err(|f| f.0)?;
		all.extend(wanted(&listed));
	}
	Ok(all)
}

/// The driver's own share of the set written once, what runs and is missing added, then what is
/// held and not wanted deleted one by one, each step read again just before it.
async fn once(driver: &Driver) -> Result<(), String> {
	let given = &driver.functions.containers.network.subnet;
	// A subnet not read leaves the set as it is, as nothing in it can be told the driver's.
	let own = subnet(given).map_err(|why| format!("the subnet {given}: {why}, nothing written"))?;
	let missing = missing(&listed_set().await?, &running(driver).await?, own);
	// Read again just before the add, so no container stopped meanwhile is let through.
	let missing: BTreeSet<Element> = missing.intersection(&running(driver).await?).copied().collect();
	if let Some(args) = written("add", &missing) {
		nft(&args).await?;
	}
	// Read again just before the deletes, so an address reused meanwhile keeps its new element.
	let (held, wanted) = (listed_set().await?, running(driver).await?);
	let mut failed = Vec::new();
	for args in deletes(&held, &wanted, own) {
		if let Err(why) = nft(&args).await
			&& !gone(&why)
		{
			failed.push(why);
		}
	}
	match failed.is_empty() {
		true => Ok(()),
		false => Err(failed.join("; ")),
	}
}

/// The set written at start and each [`PERIOD`] after, a failure told and tried again next time.
pub(super) async fn kept(driver: Arc<Driver>) {
	loop {
		if let Err(why) = once(&driver).await {
			eprintln!("fence: {why}");
		}
		tokio::time::sleep(PERIOD).await;
	}
}

#[cfg(test)]
mod tests {
	use std::collections::{BTreeMap, BTreeSet};
	use std::net::Ipv4Addr;

	use driver_machine_container::{Listed, Task};
	use serde_json::json;

	use super::{deletes, gone, held, missing, wanted, written};
	use crate::entry::subnet;

	fn container(address: &str, reaching: &str) -> Listed {
		let mut labels = BTreeMap::from([
			("driver.runs".to_owned(), "app/1".to_owned()),
			("driver.address".to_owned(), address.to_owned()),
			("driver.entry".to_owned(), "192.0.2.1:4321".to_owned()),
		]);
		if !reaching.is_empty() {
			labels.insert("driver.reaching".to_owned(), reaching.to_owned());
		}
		Listed { id: address.to_owned(), labels, task: Some(Task::Running) }
	}

	const ENTRY: Ipv4Addr = Ipv4Addr::new(192, 0, 2, 1);

	#[test]
	fn the_set_wanted_holds_each_reacher_alone() {
		let mut stopped = container("192.0.2.7:8080", "app/9");
		stopped.task = Some(Task::Stopped(0));
		let mut gone = container("192.0.2.8:8080", "app/9");
		gone.task = None;
		let listed =
			[container("192.0.2.5:8080", "app/9"), container("192.0.2.6:8080", ""), stopped, gone];
		let expected = BTreeSet::from([(Ipv4Addr::new(192, 0, 2, 5), ENTRY, 4321)]);
		assert_eq!(wanted(&listed), expected, "a running reacher's alone");
	}

	#[test]
	fn what_the_set_holds_is_read_from_nfts_listing() {
		let listing = json!({ "nftables": [
			{ "metainfo": { "version": "1.1.1" } },
			{ "set": { "family": "inet", "name": "reaching", "table": "fence", "elem": [
				{ "concat": ["192.0.2.5", "192.0.2.1", 4321] },
				{ "elem": { "val": { "concat": ["192.0.2.8", "192.0.2.1", 4321] }, "timeout": 1 } },
			] } },
		] });
		let read = held(&listing).unwrap();
		let five = (Ipv4Addr::new(192, 0, 2, 5), ENTRY, 4321);
		let eight = (Ipv4Addr::new(192, 0, 2, 8), ENTRY, 4321);
		assert_eq!(read, BTreeSet::from([five, eight]));
		let empty = json!({ "nftables": [{ "set": { "name": "reaching" } }] });
		assert_eq!(held(&empty), Some(BTreeSet::new()));
		assert_eq!(held(&json!({ "nftables": [] })), None);
	}

	#[test]
	fn the_set_is_written_by_whole_elements() {
		let two = BTreeSet::from([
			(Ipv4Addr::new(192, 0, 2, 5), ENTRY, 4321),
			(Ipv4Addr::new(192, 0, 2, 8), ENTRY, 4321),
		]);
		let expected = "{ 192.0.2.5 . 192.0.2.1 . 4321, 192.0.2.8 . 192.0.2.1 . 4321 }";
		assert_eq!(
			written("delete", &two).unwrap(),
			["delete", "element", "inet", "fence", "reaching", expected]
		);
		assert_eq!(written("add", &BTreeSet::new()), None);
	}

	#[test]
	fn each_dead_element_is_deleted_on_its_own_and_one_gone_is_no_failure() {
		let element = |last| (Ipv4Addr::new(192, 0, 2, last), ENTRY, 4321);
		let held = BTreeSet::from([element(5), element(7), element(8)]);
		let wanted = BTreeSet::from([element(5)]);
		let each = deletes(&held, &wanted, subnet("192.0.2.0/24").unwrap());
		assert_eq!(each.len(), 2);
		assert_eq!(each[0].last().unwrap(), "{ 192.0.2.7 . 192.0.2.1 . 4321 }");
		assert_eq!(each[1].last().unwrap(), "{ 192.0.2.8 . 192.0.2.1 . 4321 }");
		assert!(gone("Error: Could not process rule: No such file or directory"));
		assert!(!gone("Error: Could not process rule: Operation not permitted"));
	}

	/// An element of a reacher at `reacher`, at this test's entry.
	fn at(reacher: [u8; 4]) -> (Ipv4Addr, Ipv4Addr, u16) {
		(Ipv4Addr::from(reacher), ENTRY, 4321)
	}

	#[test]
	fn another_subnets_elements_are_left_as_they_are() {
		let own = subnet("192.0.2.0/24").unwrap();
		let held = BTreeSet::from([at([198, 51, 100, 5]), at([198, 51, 100, 6]), at([192, 0, 2, 5])]);
		let wanted = BTreeSet::from([at([192, 0, 2, 5]), at([203, 0, 113, 9])]);
		assert_eq!(deletes(&held, &wanted, own), Vec::<Vec<String>>::new());
		assert_eq!(missing(&held, &wanted, own), BTreeSet::new());
	}

	#[test]
	fn a_stale_element_of_its_own_subnet_is_still_deleted() {
		let own = subnet("192.0.2.0/24").unwrap();
		let held = BTreeSet::from([at([198, 51, 100, 7]), at([192, 0, 2, 7]), at([192, 0, 2, 5])]);
		let wanted = BTreeSet::from([at([192, 0, 2, 5])]);
		let each = deletes(&held, &wanted, own);
		assert_eq!(each.len(), 1);
		assert_eq!(each[0].last().unwrap(), "{ 192.0.2.7 . 192.0.2.1 . 4321 }");
	}

	#[test]
	fn a_wanted_element_of_its_own_subnet_is_still_added() {
		let own = subnet("192.0.2.0/24").unwrap();
		let held = BTreeSet::from([at([198, 51, 100, 5])]);
		let wanted = BTreeSet::from([at([192, 0, 2, 5])]);
		assert_eq!(missing(&held, &wanted, own), BTreeSet::from([at([192, 0, 2, 5])]));
	}
}
