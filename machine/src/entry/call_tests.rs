//! The `Call` header, kept on a request from its binding's compute component to an app alone.

use std::collections::BTreeMap;
use std::net::SocketAddr;

use axum::Router;

use super::{contained, container, echoed, entry, listening, of, of_component, sent};
use crate::entry::Found;

/// A request for `/` by a host, carrying a `Call`.
fn calling(host: &str) -> String {
	format!("GET / HTTP/1.1\r\nHost: {host}\r\nCall: 0123456789abcdef\r\nConnection: close\r\n\r\n")
}

/// An upstream echoing what it is sent, on `::1`, and its address.
async fn echoing() -> String {
	let listener = tokio::net::TcpListener::bind((std::net::Ipv6Addr::LOCALHOST, 0)).await.unwrap();
	let upstream = listener.local_addr().unwrap().to_string();
	tokio::spawn(async move { axum::serve(listener, Router::new().fallback(echoed)).await });
	upstream
}

/// The entry over app a on `::1` and, at 127.0.0.1, a container of the component named.
async fn asked_by(component: Option<&str>) -> SocketAddr {
	let upstream = echoing().await;
	let mut source = of_component("0000000c", "127.0.0.1:1");
	match component {
		Some(component) => {
			source.labels.insert("driver.component".to_owned(), component.to_owned());
		}
		// An app reaching app a by its own `reaching`.
		None => source = container("0000000c", "127.0.0.1:1", "0000000a"),
	}
	contained(vec![container("0000000a", &upstream, ""), source]).await
}

#[tokio::test]
async fn a_call_from_outside_never_reaches_the_app() {
	let (listener, upstream) = listening().await;
	tokio::spawn(async move { axum::serve(listener, Router::new().fallback(echoed)).await });
	let at = entry(BTreeMap::from([(of(1, 1), Found::Running(upstream))])).await;
	let (head, body) = sent(at, calling("00000001.b1")).await;
	assert!(head.starts_with("HTTP/1.1 201 "), "{head}");
	assert!(!body.lines().any(|l| l.starts_with("call:")), "{body}");
}

#[tokio::test]
async fn a_call_from_a_container_other_than_its_binding_s_compute_never_reaches_the_app() {
	for component in [None, Some("storage")] {
		let at = asked_by(component).await;
		let (head, body) = sent(at, calling("0000000a.b1")).await;
		// Storage reaches nothing, so its request is refused before any header is carried.
		match component {
			None => assert!(head.starts_with("HTTP/1.1 201 "), "{head}"),
			Some(_) => assert!(head.starts_with("HTTP/1.1 403 "), "{head}"),
		}
		assert!(!body.lines().any(|l| l.starts_with("call:")), "{component:?} {body}");
	}
}

#[tokio::test]
async fn the_binding_s_compute_sends_its_call_to_the_app() {
	let at = asked_by(Some("compute")).await;
	let (head, body) = sent(at, calling("0000000a.b1")).await;
	assert!(head.starts_with("HTTP/1.1 201 "), "{head}");
	assert!(body.lines().any(|l| l == "call: 0123456789abcdef"), "{body}");
}

#[tokio::test]
async fn a_call_is_kept_where_the_entry_finds_its_binding_s_compute_asking() {
	let (listener, upstream) = listening().await;
	tokio::spawn(async move { axum::serve(listener, Router::new().fallback(echoed)).await });
	let found =
		BTreeMap::from([(of(1, 1), Found::Called(upstream)), (of(1, 2), Found::Running(upstream))]);
	let at = entry(found).await;
	let (_, kept) = sent(at, calling("00000001.b1")).await;
	assert!(kept.lines().any(|l| l == "call: 0123456789abcdef"), "{kept}");
	let (_, removed) = sent(at, calling("00000002.b1")).await;
	assert!(!removed.lines().any(|l| l.starts_with("call:")), "{removed}");
}
