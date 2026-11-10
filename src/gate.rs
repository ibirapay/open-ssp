//! Liquidity reserve for Lightning sends (plans design 3.3).
//!
//! Lightning sends drain the SSP's outbound channel capacity. Below `SSP_RESERVE_SATS` the SSP refuses a send, but only for wallets that are
//! not in the priority set (Premium integrators' registered wallets), which IBIRAPAY's signup service publishes at `SSP_ENTITLEMENTS_URL`.
//! The check runs in `lightning_send_fee_estimate`, before any funds move; refusing later would strand the user's funding transfer.
//!
//! Policy, not a guarantee: a send estimated before the floor was crossed still goes through, and a client that skips the estimate is not
//! stopped. Both are accepted by design.
//!
//! Failure rules: reserve 0 = off. If the capacity cannot be read, the send is accepted (a broken ldk-server must not block every send) and
//! the error is logged. If the priority list never loaded or the feed is down, the last good list stays; before the first load nobody has
//! priority, which only matters when liquidity is already below the floor.

use std::{
    collections::HashSet,
    future::Future,
    sync::{Arc, RwLock},
    time::{Duration, Instant},
};

use tracing::{info, warn};

pub const REFUSAL: &str = "LIQUIDITY_RESERVED: liquidez reservada, tente mais tarde";
const CAPACITY_TTL: Duration = Duration::from_secs(10);
const POLL_EVERY: Duration = Duration::from_secs(30);
const MAX_FEED_BYTES: usize = 32 * 1024 * 1024; // 100.000 wallets per integrator is ~7 MB

pub struct Gate {
    reserve_sats: u64,
    capacity_ttl: Duration,
    /// Held across the fetch, so concurrent estimates share one `list_channels` call.
    capacity: tokio::sync::Mutex<Option<(Instant, u64)>>,
    /// None until the first successful poll. Lowercase hex identity public keys.
    priority: RwLock<Option<HashSet<String>>>,
}

impl Gate {
    pub fn new(reserve_sats: u64) -> Self {
        Self::with_ttl(reserve_sats, CAPACITY_TTL)
    }

    fn with_ttl(reserve_sats: u64, capacity_ttl: Duration) -> Self {
        Self {
            reserve_sats,
            capacity_ttl,
            capacity: tokio::sync::Mutex::new(None),
            priority: RwLock::new(None),
        }
    }

    pub fn reserve_sats(&self) -> u64 {
        self.reserve_sats
    }

    pub fn set_priority(&self, identities: HashSet<String>) {
        *self.priority.write().unwrap_or_else(|e| e.into_inner()) = Some(identities);
    }

    fn has_priority(&self, owner: &str) -> bool {
        self.priority
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
            .is_some_and(|set| set.contains(&owner.to_ascii_lowercase()))
    }

    /// Outbound sats, cached for the TTL. None when the capacity cannot be read (not cached: the next send asks again).
    async fn outbound_sats<F, Fut>(&self, fetch: F) -> Option<u64>
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = Result<u64, String>>,
    {
        let mut cached = self.capacity.lock().await;
        if let Some((at, sats)) = *cached {
            if at.elapsed() < self.capacity_ttl {
                return Some(sats);
            }
        }
        match fetch().await {
            Ok(sats) => {
                *cached = Some((Instant::now(), sats));
                Some(sats)
            }
            Err(e) => {
                warn!("liquidity gate: cannot read outbound capacity, accepting the send: {e}");
                None
            }
        }
    }

    /// Ok to go on, or the refusal text. `owner` is the session's identity public key (None: no session, so not in the priority set).
    pub async fn check<F, Fut>(&self, owner: Option<&str>, fetch: F) -> Result<(), String>
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = Result<u64, String>>,
    {
        if self.reserve_sats == 0 || owner.is_some_and(|o| self.has_priority(o)) {
            return Ok(());
        }
        match self.outbound_sats(fetch).await {
            Some(sats) if sats < self.reserve_sats => Err(REFUSAL.to_string()),
            _ => Ok(()),
        }
    }
}

/// `{"identities": ["<66 hex>", ...]}` -> lowercase set. One bad entry rejects the whole answer, so the last good list stays.
pub fn parse_feed(body: &[u8]) -> Result<HashSet<String>, String> {
    let value: serde_json::Value =
        serde_json::from_slice(body).map_err(|e| format!("feed json: {e}"))?;
    let list = value
        .get("identities")
        .and_then(|v| v.as_array())
        .ok_or("feed: no identities array")?;
    let mut set = HashSet::with_capacity(list.len());
    for item in list {
        let id = item.as_str().ok_or("feed: identity is not a string")?;
        if id.len() != 66 || !id.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err("feed: malformed identity".to_string());
        }
        set.insert(id.to_ascii_lowercase());
    }
    Ok(set)
}

pub async fn poll_once(
    client: &reqwest::Client,
    url: &str,
    token: &str,
) -> Result<HashSet<String>, String> {
    let response = client
        .get(url)
        .bearer_auth(token)
        .send()
        .await
        .map_err(|e| format!("feed request: {e}"))?;
    if !response.status().is_success() {
        return Err(format!("feed answered {}", response.status()));
    }
    let body = response
        .bytes()
        .await
        .map_err(|e| format!("feed body: {e}"))?;
    if body.len() > MAX_FEED_BYTES {
        return Err("feed: answer too large".to_string());
    }
    parse_feed(&body)
}

/// Polls the entitlements feed every 30 s; a failed poll keeps the last good list.
pub fn spawn_poller(gate: Arc<Gate>, url: String, token: String) {
    tokio::spawn(async move {
        let client = match reqwest::Client::builder()
            .timeout(Duration::from_secs(10))
            .build()
        {
            Ok(c) => c,
            Err(e) => {
                return warn!("liquidity gate: no HTTP client, the priority list stays empty: {e}")
            }
        };
        let mut last_size = None;
        loop {
            match poll_once(&client, &url, &token).await {
                Ok(set) => {
                    if last_size != Some(set.len()) {
                        info!("liquidity gate: priority list has {} wallets", set.len());
                        last_size = Some(set.len());
                    }
                    gate.set_priority(set);
                }
                Err(e) => {
                    warn!("liquidity gate: entitlements poll failed, keeping the last list: {e}")
                }
            }
            tokio::time::sleep(POLL_EVERY).await;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    const A: &str = "02aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const B: &str = "03bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    fn set(ids: &[&str]) -> HashSet<String> {
        ids.iter().map(|s| s.to_string()).collect()
    }

    /// A capacity source that counts its calls.
    fn source(
        sats: Result<u64, String>,
        calls: &Arc<AtomicUsize>,
    ) -> impl FnOnce() -> std::future::Ready<Result<u64, String>> {
        let calls = calls.clone();
        move || {
            calls.fetch_add(1, Ordering::SeqCst);
            std::future::ready(sats)
        }
    }

    #[tokio::test]
    async fn off_when_the_reserve_is_zero_and_never_reads_the_capacity() {
        let calls = Arc::new(AtomicUsize::new(0));
        assert!(Gate::new(0)
            .check(Some(A), source(Ok(0), &calls))
            .await
            .is_ok());
        assert_eq!(calls.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn below_the_floor_free_wallets_are_refused_and_priority_wallets_keep_sending() {
        let g = Gate::new(500_000);
        g.set_priority(set(&[A]));
        let calls = Arc::new(AtomicUsize::new(0));
        assert_eq!(
            g.check(Some(B), source(Ok(499_999), &calls)).await,
            Err(REFUSAL.to_string())
        );
        assert_eq!(
            g.check(None, source(Ok(499_999), &calls)).await,
            Err(REFUSAL.to_string()),
            "no session is not in the set"
        );
        assert!(g.check(Some(A), source(Ok(499_999), &calls)).await.is_ok());
        assert!(
            g.check(Some(&A.to_ascii_uppercase()), source(Ok(0), &calls))
                .await
                .is_ok(),
            "case does not matter"
        );
    }

    #[tokio::test]
    async fn priority_wallets_do_not_cost_a_capacity_read() {
        let g = Gate::new(500_000);
        g.set_priority(set(&[A]));
        let calls = Arc::new(AtomicUsize::new(0));
        assert!(g.check(Some(A), source(Ok(0), &calls)).await.is_ok());
        assert_eq!(calls.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn the_floor_is_strict_at_and_above_it_everyone_sends() {
        let g = Gate::new(500_000);
        let calls = Arc::new(AtomicUsize::new(0));
        assert!(g.check(Some(B), source(Ok(500_000), &calls)).await.is_ok());
        let g = Gate::new(500_000);
        assert!(g
            .check(Some(B), source(Ok(4_800_000), &calls))
            .await
            .is_ok());
    }

    #[tokio::test]
    async fn nobody_has_priority_before_the_first_load_or_with_an_empty_list() {
        let calls = Arc::new(AtomicUsize::new(0));
        let g = Gate::new(500_000);
        assert!(
            g.check(Some(A), source(Ok(1), &calls)).await.is_err(),
            "never loaded"
        );
        let g = Gate::new(500_000);
        g.set_priority(HashSet::new());
        assert!(
            g.check(Some(A), source(Ok(1), &calls)).await.is_err(),
            "empty list"
        );
        g.set_priority(set(&[A]));
        assert!(g.check(Some(A), source(Ok(1), &calls)).await.is_ok());
        g.set_priority(set(&[B]));
        assert!(
            g.check(Some(A), source(Ok(1), &calls)).await.is_err(),
            "a replaced list drops the old members"
        );
    }

    #[tokio::test]
    async fn an_unreadable_capacity_accepts_the_send_and_is_not_cached() {
        let g = Gate::new(500_000);
        let calls = Arc::new(AtomicUsize::new(0));
        assert!(g
            .check(Some(B), source(Err("down".into()), &calls))
            .await
            .is_ok());
        assert!(
            g.check(Some(B), source(Ok(1), &calls)).await.is_err(),
            "the next send asks again"
        );
        assert_eq!(calls.load(Ordering::SeqCst), 2);
    }

    #[tokio::test]
    async fn the_capacity_is_cached_for_the_ttl_and_read_again_after() {
        let calls = Arc::new(AtomicUsize::new(0));
        let g = Gate::with_ttl(500_000, Duration::from_secs(3600));
        for _ in 0..3 {
            let _ = g.check(Some(B), source(Ok(1), &calls)).await;
        }
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        let g = Gate::with_ttl(500_000, Duration::ZERO);
        for _ in 0..3 {
            let _ = g.check(Some(B), source(Ok(1), &calls)).await;
        }
        assert_eq!(calls.load(Ordering::SeqCst), 4);
    }

    #[test]
    fn the_feed_parser_lowercases_and_rejects_anything_malformed() {
        let ok = format!(
            r#"{{"identities": ["{}", "{}"]}}"#,
            A.to_ascii_uppercase(),
            B
        );
        assert_eq!(parse_feed(ok.as_bytes()).unwrap(), set(&[A, B]));
        assert_eq!(parse_feed(br#"{"identities": []}"#).unwrap().len(), 0);
        for bad in [
            "not json",
            "{}",
            r#"{"identities": "x"}"#,
            r#"{"identities": [5]}"#,
            r#"{"identities": ["02ab"]}"#,
            &format!(r#"{{"identities": ["{}", "{}"]}}"#, A, "zz".repeat(33)),
            &format!(r#"{{"identities": ["{}0"]}}"#, A),
        ] {
            assert!(parse_feed(bad.as_bytes()).is_err(), "{bad}");
        }
    }

    #[tokio::test]
    async fn the_poller_sends_the_bearer_token_and_a_failed_answer_is_an_error() {
        use axum::{
            http::{HeaderMap, StatusCode},
            routing::get,
            Router,
        };
        let body = format!(r#"{{"identities": ["{A}"]}}"#);
        let app = Router::new().route(
            "/feed",
            get(move |headers: HeaderMap| {
                let body = body.clone();
                async move {
                    if headers.get("authorization").and_then(|v| v.to_str().ok())
                        == Some("Bearer secret-token")
                    {
                        (StatusCode::OK, body)
                    } else {
                        (StatusCode::UNAUTHORIZED, String::new())
                    }
                }
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/feed", listener.local_addr().unwrap());
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let client = reqwest::Client::new();
        assert_eq!(
            poll_once(&client, &url, "secret-token").await.unwrap(),
            set(&[A])
        );
        assert!(poll_once(&client, &url, "wrong")
            .await
            .unwrap_err()
            .contains("401"));
        assert!(poll_once(&client, "http://127.0.0.1:1/feed", "x")
            .await
            .is_err());
    }
}
