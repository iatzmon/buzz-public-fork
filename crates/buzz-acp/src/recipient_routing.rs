//! Opt-in recipient selection. Relay history is authoritative; no process-local
//! participation cache can forget an old invitation or survive a deletion.

use std::time::Duration;

use anyhow::{bail, Context, Result};
use buzz_core::kind::{
    KIND_FORUM_COMMENT, KIND_FORUM_POST, KIND_STREAM_MESSAGE, KIND_STREAM_MESSAGE_V2,
};
use buzz_core::nip10::parse_thread_markers;
use nostr::Event;
use serde_json::{json, Value};
use uuid::Uuid;

use crate::pool::ChannelInfoResolver;
use crate::relay::{BuzzEvent, RestClient};

const MESSAGE_KINDS: [u32; 4] = [
    KIND_STREAM_MESSAGE,
    KIND_STREAM_MESSAGE_V2,
    KIND_FORUM_POST,
    KIND_FORUM_COMMENT,
];
const LOOKUP_TIMEOUT: Duration = Duration::from_secs(5);

/// Recipient selection for channel chat. Legacy preserves subscription rules.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, clap::ValueEnum)]
pub enum RecipientPolicy {
    #[default]
    Legacy,
    /// Mentions override thread participants; unmentioned roots address everyone.
    Conversation,
}

pub(crate) struct RoutingContext<'a> {
    pub policy: RecipientPolicy,
    pub rest: &'a RestClient,
    pub channels: &'a ChannelInfoResolver,
    pub owner: Option<&'a str>,
}

impl RoutingContext<'_> {
    pub async fn match_subscription(
        &self,
        event: &BuzzEvent,
        rules: &[crate::filter::SubscriptionRule],
        agent: &str,
    ) -> Option<crate::filter::MatchedRule> {
        let conversation = self.applies(event).await;
        let conversation_rules;
        let rules = if conversation {
            conversation_rules = rules
                .iter()
                .cloned()
                .map(|mut rule| {
                    rule.require_mention = false;
                    rule
                })
                .collect::<Vec<_>>();
            &conversation_rules
        } else {
            rules
        };
        let matched =
            crate::filter::match_event(&event.event, event.channel_id, rules, agent).await?;
        if conversation {
            match self.accepts(event, agent).await {
                Ok(true) => {}
                Ok(false) => return None,
                Err(error) => {
                    tracing::warn!(event_id = %event.event.id, %error,
                        "recipient lookup failed; event not admitted (explicit mention can retry)");
                    return None;
                }
            }
        }
        Some(matched)
    }

    pub async fn applies(&self, event: &BuzzEvent) -> bool {
        if self.policy != RecipientPolicy::Conversation || !is_message(&event.event) {
            return false;
        }
        // Only a confirmed DM retains its existing routing. Unknown metadata
        // must not bypass recipient selection in a broad subscription.
        self.channels
            .resolve_channel_metadata(event.channel_id)
            .await
            .is_none_or(|info| info.channel_type != "dm")
    }

    pub async fn accepts(&self, event: &BuzzEvent, agent: &str) -> Result<bool> {
        tokio::time::timeout(LOOKUP_TIMEOUT, accepts(event, agent, self.owner, self.rest))
            .await
            .context("recipient lookup timed out")?
    }
}

fn is_message(event: &Event) -> bool {
    MESSAGE_KINDS.contains(&(event.kind.as_u16() as u32))
}

/// None means no explicit addressing. Even a malformed p tag suppresses the
/// broadcast fallback rather than accidentally waking the whole channel.
fn explicit_recipient(event: &Event, agent: &str) -> Option<bool> {
    let mut addressed = false;
    for tag in event.tags.iter() {
        let parts = tag.as_slice();
        if parts.first().is_some_and(|kind| kind == "p") {
            addressed = true;
            if parts
                .get(1)
                .is_some_and(|key| key.eq_ignore_ascii_case(agent))
            {
                return Some(true);
            }
        }
    }
    addressed.then_some(false)
}

fn has_agent_attestation(event: &Event) -> bool {
    event
        .tags
        .iter()
        .any(|tag| tag.as_slice().first().is_some_and(|kind| kind == "auth"))
}

fn in_channel(event: &Event, channel: Uuid) -> bool {
    event.tags.iter().any(|tag| {
        let parts = tag.as_slice();
        parts.first().is_some_and(|kind| kind == "h")
            && parts.get(1).and_then(|id| id.parse::<Uuid>().ok()) == Some(channel)
    })
}

fn parse_events(value: Value) -> Result<Vec<Event>> {
    let values = value
        .as_array()
        .context("recipient query response is not an array")?;
    values
        .iter()
        .map(|value| {
            let event: Event =
                serde_json::from_value(value.clone()).context("invalid recipient evidence")?;
            event
                .verify()
                .context("invalid recipient evidence signature")?;
            Ok(event)
        })
        .collect()
}

async fn accepts(
    event: &BuzzEvent,
    agent: &str,
    owner: Option<&str>,
    rest: &RestClient,
) -> Result<bool> {
    let message = &event.event;
    if message.pubkey.to_hex().eq_ignore_ascii_case(agent) {
        return Ok(false);
    }
    if let Some(mentioned) = explicit_recipient(message, agent) {
        return Ok(mentioned);
    }
    // Agent replies must explicitly address another agent. An attestation is
    // sufficient to suppress implicit delivery, never to grant permission.
    if has_agent_attestation(message) {
        return Ok(false);
    }
    if owner != Some(message.pubkey.to_hex().as_str()) {
        let profiles = parse_events(
            rest.query_raw(&[json!({
                "kinds": [0], "authors": [message.pubkey.to_hex()], "limit": 1
            })])
            .await?,
        )?;
        let profile = profiles
            .first()
            .context("author profile unavailable; use an explicit mention")?;
        if profile.kind.as_u16() != 0 || profile.pubkey != message.pubkey {
            bail!("author profile query returned unrelated evidence");
        }
        let metadata: Value =
            serde_json::from_str(&profile.content).context("invalid author profile")?;
        if has_agent_attestation(profile)
            || metadata.get("bot").and_then(Value::as_bool) == Some(true)
        {
            return Ok(false);
        }
    }
    let Some((root, _)) = parse_thread_markers(&message.tags).resolve() else {
        return Ok(true);
    };
    let root = root.to_ascii_lowercase();
    // Root and participant queries are channel-scoped and independent of the
    // prompt-history window. A restart needs no local state reconstruction.
    let roots = parse_events(
        rest.query_raw(&[json!({
            "kinds": MESSAGE_KINDS, "ids": [&root], "#h": [event.channel_id.to_string()], "limit": 1
        })])
        .await?,
    )?;
    let root_event = roots
        .first()
        .context("thread root unavailable; use an explicit mention")?;
    if root_event.id.to_hex() != root
        || !in_channel(root_event, event.channel_id)
        || !is_message(root_event)
    {
        bail!("thread root query returned unrelated evidence");
    }
    if participates(root_event, agent) {
        return Ok(true);
    }
    for selector in [json!({"authors": [agent]}), json!({"#p": [agent]})] {
        let mut filter = json!({
            "kinds": MESSAGE_KINDS, "#h": [event.channel_id.to_string()],
            "#e": [&root], "until": message.created_at.as_secs()
        });
        if let (Some(target), Some(extra)) = (filter.as_object_mut(), selector.as_object()) {
            target.extend(extra.clone());
        }
        // Bounded, composite-cursor pagination: a full page cannot be mistaken
        // for absence, including many events sharing the same timestamp.
        for value in rest.query_raw_all(filter).await? {
            let evidence = parse_events(json!([value]))?
                .pop()
                .context("missing participant evidence")?;
            let same_thread = parse_thread_markers(&evidence.tags)
                .resolve()
                .is_some_and(|(candidate, _)| candidate.eq_ignore_ascii_case(&root));
            if is_message(&evidence)
                && in_channel(&evidence, event.channel_id)
                && same_thread
                && evidence.created_at <= message.created_at
                && participates(&evidence, agent)
            {
                return Ok(true);
            }
        }
    }
    Ok(false)
}

fn participates(event: &Event, agent: &str) -> bool {
    event.pubkey.to_hex().eq_ignore_ascii_case(agent)
        || explicit_recipient(event, agent) == Some(true)
}

#[cfg(test)]
mod tests;
