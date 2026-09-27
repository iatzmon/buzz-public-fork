use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use buzz_auth::{LimitType, RateLimiter};
use buzz_core::TenantContext;
use nostr::PublicKey;

// Desktop startup establishes several independent live subscriptions at once.
// Preserve the configured average rate while allowing that bounded burst. This
// is still a fixed-window limiter, so a Redis-backed token bucket would be a
// better long-term fit for smoother refill behavior.
const WS_BURST_WINDOW_SECS: u64 = 5;

/// Upper bound on principals tracked by the local fallback. Admission runs
/// only for authenticated callers, so this is far above any single relay's
/// active principal count.
const LOCAL_FALLBACK_MAX_ENTRIES: u64 = 100_000;
/// Idle time after which a local fallback window is dropped. Longer than every
/// admission window, so an evicted entry would have reset anyway.
const LOCAL_FALLBACK_IDLE: Duration = Duration::from_secs(10 * 60);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum AdmissionError {
    Exceeded { reset_in_secs: u64 },
    Unavailable,
}

/// Process-local fixed-window counters that decide admission when the shared
/// Redis counter cannot answer.
///
/// Opt-in via `BUZZ_ADMISSION_LOCAL_FALLBACK` for single-instance relays. Every
/// attempt is counted here once, before Redis is asked, with the same limits
/// and windows as the shared counter. So the local window holds the same total
/// whether Redis answers, fails, or recovers, and the count does not depend on
/// the order in which concurrent Redis replies complete. With several relay
/// instances each would count separately, which is why the default is to
/// reject instead.
pub(crate) struct LocalAdmissionFallback {
    windows: moka::sync::Cache<String, Arc<Mutex<(Instant, u64)>>>,
}

impl LocalAdmissionFallback {
    pub(crate) fn new() -> Self {
        Self {
            windows: moka::sync::Cache::builder()
                .max_capacity(LOCAL_FALLBACK_MAX_ENTRIES)
                .time_to_idle(LOCAL_FALLBACK_IDLE)
                .build(),
        }
    }

    /// Counts one attempt in the local window and returns the local verdict.
    fn check(
        &self,
        key: String,
        window_secs: u64,
        limit: u64,
        now: Instant,
    ) -> Result<(), AdmissionError> {
        let window = Duration::from_secs(window_secs.max(1));
        let entry = self
            .windows
            .get_with(key, || Arc::new(Mutex::new((now, 0))));
        let mut guard = entry.lock().unwrap_or_else(PoisonError::into_inner);
        if now.saturating_duration_since(guard.0) >= window {
            *guard = (now, 0);
        }
        guard.1 = guard.1.saturating_add(1);
        if guard.1 <= limit {
            return Ok(());
        }
        let remaining = window.saturating_sub(now.saturating_duration_since(guard.0));
        Err(AdmissionError::Exceeded {
            reset_in_secs: remaining.as_secs().max(1),
        })
    }
}

pub(crate) async fn check_principal<L: RateLimiter>(
    limiter: &L,
    fallback: Option<&LocalAdmissionFallback>,
    tenant: &TenantContext,
    pubkey: &PublicKey,
    limit_type: LimitType,
    window_secs: u64,
    limit: u64,
) -> Result<(), AdmissionError> {
    let local_verdict = fallback.map(|fallback| {
        let key = buzz_auth::rate_limit::rate_limit_key(tenant, pubkey, &limit_type);
        fallback.check(key, window_secs, limit, Instant::now())
    });
    match limiter
        .check_and_increment(tenant, pubkey, limit_type, window_secs, limit)
        .await
    {
        Ok(result) if !result.allowed => Err(AdmissionError::Exceeded {
            reset_in_secs: result.reset_in_secs,
        }),
        // Admissions made while Redis was down are only in the local window,
        // so a recovered Redis cannot grant what the local window has spent.
        Ok(_) => local_verdict.unwrap_or(Ok(())),
        Err(error) => match local_verdict {
            Some(verdict) => {
                tracing::warn!(error = %error, "shared rate-limit admission unavailable; using local fallback");
                metrics::counter!("buzz_admission_local_fallback_total").increment(1);
                verdict
            }
            None => {
                tracing::warn!(error = %error, "shared rate-limit admission unavailable");
                Err(AdmissionError::Unavailable)
            }
        },
    }
}

pub(crate) fn ws_admission_budget(per_second_limit: u64) -> (u64, u64) {
    (
        WS_BURST_WINDOW_SECS,
        per_second_limit.saturating_mul(WS_BURST_WINDOW_SECS),
    )
}

#[cfg(test)]
mod tests {
    use std::net::IpAddr;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use buzz_auth::{AuthError, RateLimitResult, RateLimiter};
    use buzz_core::CommunityId;
    use nostr::Keys;
    use uuid::Uuid;

    use super::*;

    enum StubOutcome {
        Denied,
        Failed,
    }

    struct StubLimiter {
        outcome: StubOutcome,
        calls: AtomicUsize,
    }

    impl RateLimiter for StubLimiter {
        async fn check_and_increment(
            &self,
            _ctx: &TenantContext,
            _pubkey: &PublicKey,
            _limit_type: LimitType,
            _window_secs: u64,
            _limit: u64,
        ) -> Result<RateLimitResult, AuthError> {
            self.calls.fetch_add(1, Ordering::Relaxed);
            match self.outcome {
                StubOutcome::Denied => Ok(RateLimitResult::denied(11, 10, 1)),
                StubOutcome::Failed => Err(AuthError::Internal("redis unavailable".to_owned())),
            }
        }

        async fn check_ip_connection(
            &self,
            _ip: &IpAddr,
            _window_secs: u64,
            _limit: u64,
        ) -> Result<RateLimitResult, AuthError> {
            match self.outcome {
                StubOutcome::Denied => Ok(RateLimitResult::denied(11, 10, 1)),
                StubOutcome::Failed => Err(AuthError::Internal("redis unavailable".to_owned())),
            }
        }
    }

    fn tenant() -> TenantContext {
        TenantContext::resolved(
            CommunityId::from_uuid(Uuid::from_u128(1)),
            "relay.example.com",
        )
    }

    #[test]
    fn websocket_budget_preserves_rate_with_a_bounded_burst() {
        assert_eq!(ws_admission_budget(10), (5, 50));
    }

    #[test]
    fn websocket_budget_saturates_on_overflow() {
        assert_eq!(ws_admission_budget(u64::MAX), (5, u64::MAX));
    }

    #[tokio::test]
    async fn denied_shared_counter_rejects_admission() {
        let limiter = StubLimiter {
            outcome: StubOutcome::Denied,
            calls: AtomicUsize::new(0),
        };
        let keys = Keys::generate();

        let fallback = LocalAdmissionFallback::new();

        let result = check_principal(
            &limiter,
            Some(&fallback),
            &tenant(),
            &keys.public_key(),
            LimitType::WsEvents,
            1,
            10,
        )
        .await;

        // A shared-counter denial is authoritative; the local fallback never
        // overrides it.
        assert_eq!(result, Err(AdmissionError::Exceeded { reset_in_secs: 1 }));
        assert_eq!(limiter.calls.load(Ordering::Relaxed), 1);
    }

    #[tokio::test]
    async fn shared_counter_failure_rejects_admission() {
        let limiter = StubLimiter {
            outcome: StubOutcome::Failed,
            calls: AtomicUsize::new(0),
        };
        let keys = Keys::generate();

        let result = check_principal(
            &limiter,
            None,
            &tenant(),
            &keys.public_key(),
            LimitType::ApiCalls,
            60,
            300,
        )
        .await;

        assert_eq!(result, Err(AdmissionError::Unavailable));
        assert_eq!(limiter.calls.load(Ordering::Relaxed), 1);
    }

    #[tokio::test]
    async fn shared_counter_failure_uses_local_fallback_with_same_limit() {
        let limiter = StubLimiter {
            outcome: StubOutcome::Failed,
            calls: AtomicUsize::new(0),
        };
        let fallback = LocalAdmissionFallback::new();
        let keys = Keys::generate();

        let mut results = Vec::new();
        for _ in 0..4 {
            results.push(
                check_principal(
                    &limiter,
                    Some(&fallback),
                    &tenant(),
                    &keys.public_key(),
                    LimitType::Messages,
                    60,
                    3,
                )
                .await,
            );
        }

        assert_eq!(results[..3], [Ok(()), Ok(()), Ok(())]);
        assert!(
            matches!(results[3], Err(AdmissionError::Exceeded { reset_in_secs }) if (1..=60).contains(&reset_in_secs)),
            "the fourth call must exceed the limit of three: {:?}",
            results[3]
        );
        assert_eq!(limiter.calls.load(Ordering::Relaxed), 4);
    }

    #[tokio::test]
    async fn local_fallback_counts_principals_and_limit_types_separately() {
        let limiter = StubLimiter {
            outcome: StubOutcome::Failed,
            calls: AtomicUsize::new(0),
        };
        let fallback = LocalAdmissionFallback::new();
        let tenant = tenant();
        let first = Keys::generate().public_key();
        let second = Keys::generate().public_key();

        let (limiter, fallback, tenant) = (&limiter, &fallback, &tenant);
        let check = |pubkey: PublicKey, limit_type: LimitType| async move {
            check_principal(limiter, Some(fallback), tenant, &pubkey, limit_type, 60, 1).await
        };

        assert_eq!(check(first, LimitType::Messages).await, Ok(()));
        assert_eq!(check(second, LimitType::Messages).await, Ok(()));
        assert_eq!(check(first, LimitType::ApiCalls).await, Ok(()));
        assert!(matches!(
            check(first, LimitType::Messages).await,
            Err(AdmissionError::Exceeded { .. })
        ));
    }

    #[test]
    fn local_fallback_window_resets_after_it_expires() {
        let fallback = LocalAdmissionFallback::new();
        let start = Instant::now();
        let key = || "buzz:test:ratelimit:principal:messages".to_owned();

        assert_eq!(fallback.check(key(), 5, 1, start), Ok(()));
        assert_eq!(
            fallback.check(key(), 5, 1, start + Duration::from_secs(2)),
            Err(AdmissionError::Exceeded { reset_in_secs: 3 })
        );
        assert_eq!(
            fallback.check(key(), 5, 1, start + Duration::from_secs(5)),
            Ok(())
        );
    }

    /// Answers each call with the next scripted outcome: `Some` is a shared
    /// counter result, `None` is a Redis failure.
    struct ScriptedLimiter {
        outcomes: Mutex<std::collections::VecDeque<Option<RateLimitResult>>>,
    }

    impl ScriptedLimiter {
        fn new(outcomes: Vec<Option<RateLimitResult>>) -> Self {
            Self {
                outcomes: Mutex::new(outcomes.into()),
            }
        }
    }

    impl RateLimiter for ScriptedLimiter {
        async fn check_and_increment(
            &self,
            _ctx: &TenantContext,
            _pubkey: &PublicKey,
            _limit_type: LimitType,
            _window_secs: u64,
            _limit: u64,
        ) -> Result<RateLimitResult, AuthError> {
            let next = self
                .outcomes
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .pop_front()
                .expect("scripted outcome");
            next.ok_or_else(|| AuthError::Internal("redis unavailable".to_owned()))
        }

        async fn check_ip_connection(
            &self,
            _ip: &IpAddr,
            _window_secs: u64,
            _limit: u64,
        ) -> Result<RateLimitResult, AuthError> {
            Err(AuthError::Internal("not used".to_owned()))
        }
    }

    async fn run_script(outcomes: Vec<Option<RateLimitResult>>) -> Vec<Result<(), AdmissionError>> {
        let calls = outcomes.len();
        let limiter = ScriptedLimiter::new(outcomes);
        let fallback = LocalAdmissionFallback::new();
        let tenant = tenant();
        let pubkey = Keys::generate().public_key();
        let mut results = Vec::with_capacity(calls);
        for _ in 0..calls {
            results.push(
                check_principal(
                    &limiter,
                    Some(&fallback),
                    &tenant,
                    &pubkey,
                    LimitType::Messages,
                    60,
                    3,
                )
                .await,
            );
        }
        results
    }

    fn shared_allowed(current: u64) -> Option<RateLimitResult> {
        Some(RateLimitResult::allowed(current, 3, 55))
    }

    #[tokio::test]
    async fn fallback_continues_from_the_shared_count_when_redis_fails() {
        let results = run_script(vec![
            shared_allowed(1),
            shared_allowed(2),
            shared_allowed(3),
            None,
            None,
            None,
        ])
        .await;

        assert_eq!(results[..3], [Ok(()), Ok(()), Ok(())]);
        for result in &results[3..] {
            assert!(
                matches!(result, Err(AdmissionError::Exceeded { .. })),
                "a Redis failure must not reopen a spent window: {results:?}"
            );
        }
    }

    #[tokio::test]
    async fn fallback_admissions_still_count_after_redis_recovers() {
        // Redis never saw the three fallback admissions, so it reports a low
        // count after recovery; the local window must still refuse.
        let results = run_script(vec![None, None, None, shared_allowed(1)]).await;

        assert_eq!(results[..3], [Ok(()), Ok(()), Ok(())]);
        assert!(
            matches!(results[3], Err(AdmissionError::Exceeded { .. })),
            "recovery must not grant a fourth admission: {results:?}"
        );
    }

    #[tokio::test]
    async fn out_of_order_shared_replies_do_not_double_count() {
        // Concurrent requests can complete out of order, so the shared counts
        // arrive as 3, 2, 1. All three are within the limit of three.
        let results = run_script(vec![
            shared_allowed(3),
            shared_allowed(2),
            shared_allowed(1),
        ])
        .await;

        assert_eq!(results, [Ok(()), Ok(()), Ok(())]);
    }

    #[tokio::test]
    async fn shared_denial_stays_authoritative_with_a_fresh_local_window() {
        let results = run_script(vec![Some(RateLimitResult::denied(4, 3, 9))]).await;

        assert_eq!(
            results,
            [Err(AdmissionError::Exceeded { reset_in_secs: 9 })]
        );
    }

    #[tokio::test]
    async fn mixed_outcomes_admit_exactly_the_limit_in_one_window() {
        let results = run_script(vec![
            shared_allowed(1),
            None,
            shared_allowed(2),
            None,
            shared_allowed(3),
        ])
        .await;

        let admitted = results.iter().filter(|result| result.is_ok()).count();
        assert_eq!(
            admitted, 3,
            "one window admits the limit, no more: {results:?}"
        );
        assert!(matches!(results[4], Err(AdmissionError::Exceeded { .. })));
    }
}
