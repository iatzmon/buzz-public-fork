//! Per-session usage for the Sessions view: tokens and cost from the usage
//! reports of each running agent session that this archive holds. Reports
//! the archive never received are not counted, so a total can be low without
//! being marked incomplete.
//!
//! Reuses the NIP-AM accounting ladder in [`super::agent_usage`] so a session
//! total can never disagree with the usage series for the same rows. NIP-AM
//! reports arrive once per completed turn, so the in-flight turn is never
//! included.

use rusqlite::Connection;
use serde::{Deserialize, Serialize};

use super::agent_usage::{self, ReportedUsage};
use super::metric_store;

/// Upper bound on sessions per request. One agent runs at most 32 parallel
/// sessions (`BUZZ_ACP_AGENTS`), so this is defense in depth only.
const MAX_SESSIONS: usize = 64;
/// Upper bound on one session id's length; harness ids are short.
const MAX_SESSION_ID_LEN: usize = 256;

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentSessionUsageRequest {
    pub agent_pubkey: String,
    pub session_ids: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionUsage {
    pub session_id: String,
    pub usage: ReportedUsage,
    /// Completed turns with a usage report in this session.
    pub report_count: i64,
}

/// Validate the request and return the normalized agent pubkey plus the
/// de-duplicated session ids. Fails closed before any SQLite work.
fn validate_request(req: &AgentSessionUsageRequest) -> Result<(String, Vec<String>), String> {
    let pk = &req.agent_pubkey;
    if pk.len() != 64 || !pk.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err("agent_pubkey must be exactly 64 hex characters".to_string());
    }
    if req.session_ids.len() > MAX_SESSIONS {
        return Err(format!("at most {MAX_SESSIONS} session ids per request"));
    }
    let mut sessions: Vec<String> = Vec::with_capacity(req.session_ids.len());
    for id in &req.session_ids {
        if id.is_empty() || id.len() > MAX_SESSION_ID_LEN {
            return Err("session ids must be 1 to 256 characters".to_string());
        }
        if !sessions.contains(id) {
            sessions.push(id.clone());
        }
    }
    Ok((pk.to_lowercase(), sessions))
}

/// Synchronous SQLite core of the `get_agent_session_usage` command. Sessions
/// with no valid usage report are omitted, so the caller shows "unknown"
/// rather than a false zero.
pub(super) fn agent_session_usage(
    conn: &Connection,
    identity_pk: &str,
    relay_url: &str,
    request: &AgentSessionUsageRequest,
) -> Result<Vec<SessionUsage>, String> {
    let (agent_pk, session_ids) = validate_request(request)?;
    metric_store::backfill_agent_metric_index(conn, identity_pk, relay_url)?;
    metric_store::repair_orphaned_metric_index_rows(conn, identity_pk, relay_url)?;

    let mut out = Vec::with_capacity(session_ids.len());
    for session_id in session_ids {
        let rows = metric_store::load_session_valid_rows(
            conn,
            identity_pk,
            relay_url,
            &agent_pk,
            &session_id,
        )?;
        if rows.is_empty() {
            continue;
        }
        // Every valid row of the session is already loaded, so it doubles as
        // the probe set (same key and validity filters as
        // `load_rows_at_exact_keys`). One unbounded bucket: each row counts once.
        let series =
            agent_usage::compute_series(&rows, &rows, 0, &[i64::MIN, i64::MAX], None, true);
        if let Some(agent) = series.agents.into_iter().next() {
            out.push(SessionUsage {
                session_id,
                usage: agent.usage,
                report_count: agent.report_count,
            });
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::archive::store::{self, SCHEMA};

    const IDENTITY: &str = "1111111111111111111111111111111111111111111111111111111111111111";
    const AGENT: &str = "2222222222222222222222222222222222222222222222222222222222222222";
    const RELAY: &str = "wss://relay.example";

    fn in_memory() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(SCHEMA).unwrap();
        conn
    }

    fn insert_metric(conn: &Connection, id: &str, session: &str, seq: u64, cumulative: u64) {
        let raw = format!(
            r#"{{"harness":"claude","model":"m","channelId":null,"sessionId":"{session}","turnId":null,"turnSeq":{seq},"timestamp":"2026-07-01T00:00:0{seq}Z","turn":{{"totalTokens":30}},"cumulative":{{"totalTokens":{cumulative}}},"deltaReliable":true,"stopReason":"end_turn"}}"#
        );
        store::upsert_archived_event(
            conn,
            IDENTITY,
            RELAY,
            id,
            44200,
            AGENT,
            1_782_864_000 + seq as i64,
            &raw,
            1_782_864_100,
        )
        .unwrap();
    }

    fn request(sessions: &[&str]) -> AgentSessionUsageRequest {
        AgentSessionUsageRequest {
            agent_pubkey: AGENT.to_uppercase(),
            session_ids: sessions.iter().map(|s| s.to_string()).collect(),
        }
    }

    #[test]
    fn totals_each_session_separately_and_omits_unknown_sessions() {
        let conn = in_memory();
        // s1: first turn has no baseline (direct 30), second diffs 450-300.
        insert_metric(&conn, "a1", "s1", 1, 300);
        insert_metric(&conn, "a2", "s1", 2, 450);
        insert_metric(&conn, "b1", "s2", 1, 900);

        let usage =
            agent_session_usage(&conn, IDENTITY, RELAY, &request(&["s1", "s1", "none"])).unwrap();

        assert_eq!(usage.len(), 1, "unknown session omitted, duplicate folded");
        assert_eq!(usage[0].session_id, "s1");
        assert_eq!(usage[0].report_count, 2);
        assert_eq!(usage[0].usage.total_tokens.value.as_deref(), Some("180"));
        assert!(!usage[0].usage.total_tokens.incomplete);
    }

    #[test]
    fn rejects_malformed_requests_before_reading() {
        let conn = in_memory();
        let mut bad_pk = request(&["s1"]);
        bad_pk.agent_pubkey = "abc".into();
        assert!(agent_session_usage(&conn, IDENTITY, RELAY, &bad_pk).is_err());
        assert!(agent_session_usage(&conn, IDENTITY, RELAY, &request(&[""])).is_err());
        let too_many: Vec<String> = (0..=MAX_SESSIONS).map(|i| format!("s{i}")).collect();
        let refs: Vec<&str> = too_many.iter().map(String::as_str).collect();
        assert!(agent_session_usage(&conn, IDENTITY, RELAY, &request(&refs)).is_err());
    }
}
