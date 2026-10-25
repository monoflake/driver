//! One component id named three ways, its container, its route at the entry and its key in
//! `MONOFLAKE_REACHING`, each built by the code that names it and held to one spelling, RFC y2xd3.

use std::collections::BTreeMap;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use driver_machine_container::{
	Attachment, Binding, Capacity, Containerd, Containers, Deployments as _, Fault, Fetch, Image,
	ImageConfig, Listed, Mount, Network, Quota, Runtimes, Spec, Task, Unfetched,
};
use envelope::contracts::{
	DeploymentArtifact, DeploymentDeploy, DeploymentForm, DeploymentIsolation, DeploymentRuns,
};

use super::{Named, Written, named};

/// What a container was made as, in order.
#[derive(Default)]
struct Made(Mutex<Vec<(String, Spec, Option<Task>)>>);

impl Containerd for Made {
	async fn import(&self, _: &str, _: &Path) -> Result<Image, Fault> {
		let config = ImageConfig { cmd: vec!["/bin/sh".into()], ..ImageConfig::default() };
		Ok(Image { name: "image".into(), chain: "sha256:top".into(), config, size: 1 })
	}
	async fn prepare(&self, _: &str, _: &str, _: &Image) -> Result<Vec<Mount>, Fault> {
		Ok(Vec::new())
	}
	async fn snapshot_path(&self, _: &str, _: &str) -> Result<PathBuf, Fault> {
		Ok(std::env::temp_dir().join("driver-machine-one-id-rootfs"))
	}
	async fn create(&self, _: &str, spec: &Spec, _: &[Mount], _: &Path) -> Result<(), Fault> {
		self.0.lock().unwrap().push((spec.id.clone(), spec.clone(), Some(Task::Created)));
		Ok(())
	}
	async fn start(&self, _: &str, id: &str) -> Result<u32, Fault> {
		for made in self.0.lock().unwrap().iter_mut().filter(|m| m.0 == id) {
			made.2 = Some(Task::Running);
		}
		Ok(1)
	}
	async fn stop(&self, _: &str, _: &str, _: u64) -> Result<(), Fault> {
		Ok(())
	}
	async fn remove(&self, _: &str, _: &str) -> Result<(), Fault> {
		Ok(())
	}
	async fn list(&self, _: &str) -> Result<Vec<Listed>, Fault> {
		let made = self.0.lock().unwrap();
		Ok(
			made
				.iter()
				.map(|(id, s, t)| Listed { id: id.clone(), labels: s.labels.clone(), task: *t })
				.collect(),
		)
	}
}

/// A bridge giving each container the next address.
#[derive(Default)]
struct Given(Mutex<u8>);

impl Network for Given {
	async fn attach(&self, id: &str, port: u16) -> Result<Attachment, Fault> {
		let mut given = self.0.lock().unwrap();
		*given += 1;
		let address = SocketAddr::from(([192, 0, 2, *given + 1], port));
		let netns = PathBuf::from("/run/netns").join(id);
		Ok(Attachment { netns, address, entry: SocketAddr::from(([192, 0, 2, 1], 4321)) })
	}
	async fn detach(&self, _: &str) -> Result<(), Fault> {
		Ok(())
	}
	async fn reached(&self, _: SocketAddr) -> bool {
		true
	}
	async fn fence(&self, _: &str, _: &[SocketAddr]) -> Result<(), Fault> {
		Ok(())
	}
}

struct Room;

impl Quota for Room {
	async fn assign(&self, _: &Path, _: &str) -> Result<(), Fault> {
		Ok(())
	}
	async fn limit(&self, _: &str, _: Option<u64>) -> Result<(), Fault> {
		Ok(())
	}
}

/// Every artifact fetched as the same bytes, under the hash the deploys name.
struct Served;

const HASH: [u8; 32] = [7; 32];

impl Fetch for Served {
	async fn fetch(&self, _: &str, into: &Path, _: u64) -> Result<[u8; 32], Unfetched> {
		std::fs::write(into, b"image").unwrap();
		Ok(HASH)
	}
}

fn deploy(runs: DeploymentRuns, reaching: Option<Vec<DeploymentRuns>>) -> DeploymentDeploy {
	DeploymentDeploy {
		runs,
		version: HASH,
		form: DeploymentForm::Image,
		runtime: None,
		isolation: vec![DeploymentIsolation::Kernel],
		artifact: DeploymentArtifact {
			address: "file:///image.tar".into(),
			hash: HASH,
			architecture: None,
		},
		footing: "https://footing.example".into(),
		secrets: BTreeMap::new(),
		network: Vec::new(),
		into: None,
		port: Some(8080),
		handed: None,
		reaching,
	}
}

#[tokio::test]
async fn a_components_id_is_one_spelling_in_its_container_its_route_and_its_key() {
	let state = std::env::temp_dir().join("driver-machine-one-id");
	let _ = std::fs::remove_dir_all(&state);
	std::fs::create_dir_all(std::env::temp_dir().join("driver-machine-one-id-rootfs")).unwrap();
	let containers = Containers {
		containerd: Made::default(),
		network: Given::default(),
		quota: Room,
		fetch: Served,
		runtimes: Runtimes {
			runc: "/bin/runc".into(),
			crun: "/bin/crun".into(),
			youki: "/bin/youki".into(),
		},
		state: state.clone(),
		secrets: state.join("tmpfs"),
		largest: 1 << 20,
	};
	// A binding whose decimal and hex differ, as an id drawn from now on.
	let bound = 0x0a1b_2c3d;
	let binding = Binding {
		namespace: crate::listed::namespace(bound),
		qgroup: driver_machine_volume::qgroup(bound),
		capacities: BTreeMap::from([(1, Capacity { millicores: 100, memory: 1 << 26 })]),
	};
	// An id whose decimal and hex differ.
	let id = 0x1a2b_3c4d;
	let component = DeploymentRuns::Component { component: "stand-in".into(), id };
	containers.deploy(&binding, deploy(component.clone(), None)).await.unwrap();
	let reacher = DeploymentRuns::App { id: 1 };
	containers.deploy(&binding, deploy(reacher, Some(vec![component]))).await.unwrap();
	let made = containers.containerd.0.lock().unwrap().clone();
	let [(container, _, _), (_, spec, _)] = made.as_slice() else { panic!("{}", made.len()) };
	let env = spec.runtime_spec["process"]["env"].as_array().unwrap();
	let reaching = env
		.iter()
		.filter_map(|e| e.as_str()?.split_once('='))
		.find(|(n, _)| *n == "MONOFLAKE_REACHING");
	let origins: serde_json::Value = serde_json::from_str(reaching.unwrap().1).unwrap();
	let (key, origin) = origins.as_object().unwrap().iter().next().unwrap();
	let route = Named { binding: bound, written: Written::Hex, id }.name();
	// The origin's host is the route the entry takes back to the same component.
	let host = origin.as_str().unwrap().trim_start_matches("http://");
	assert_eq!(named(host), Some(Named { binding: bound, written: Written::Hex, id }));
	// At the port the attachment answered.
	assert_eq!(host.rsplit_once(':').map(|(_, port)| port), Some("4321"));
	// The name handed is the name the entry gives the route, its binding in hex too.
	assert_eq!(host, format!("{route}:4321"));
	let of_container = container.split('-').next().unwrap();
	let of_route = route.split('.').next().unwrap();
	assert_eq!((of_container, of_route), (key.as_str(), key.as_str()));
	assert!(key.len() == 8 && key.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f')), "{key}");
	assert_ne!(key.as_str(), id.to_string(), "written in hex, not decimal");
}
