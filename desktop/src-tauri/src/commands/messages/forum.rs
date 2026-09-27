use tauri::State;

use crate::{
    app_state::AppState,
    models::{
        ForumMessageInfo, ForumPostsResponse, ForumThreadReplyInfo, ForumThreadResponse,
        ThreadSummary,
    },
    relay::query_relay,
};

pub(super) async fn fetch_agent_owner_pubkeys(
    state: &AppState,
    events: &[nostr::Event],
) -> std::collections::HashMap<String, String> {
    let authors = events
        .iter()
        .map(|event| event.pubkey.to_hex())
        .collect::<std::collections::HashSet<_>>()
        .into_iter()
        .collect::<Vec<_>>();
    if authors.is_empty() {
        return std::collections::HashMap::new();
    }

    let profiles = super::query_relay(
        state,
        &[serde_json::json!({ "kinds": [0], "authors": authors })],
    )
    .await
    .unwrap_or_default();
    agent_owner_pubkeys_from_profiles(&profiles)
}

/// Maps each agent pubkey to its verified NIP-OA owner, read from the agent's
/// own kind:0 profile. Profiles without a valid owner attestation are skipped.
pub(super) fn agent_owner_pubkeys_from_profiles(
    profiles: &[nostr::Event],
) -> std::collections::HashMap<String, String> {
    profiles
        .iter()
        .filter_map(|profile| {
            crate::nostr_convert::profile_valid_oa_owner_pubkey(profile)
                .map(|owner| (profile.pubkey.to_hex(), owner))
        })
        .collect()
}

fn tags_to_vec(event: &nostr::Event) -> Vec<Vec<String>> {
    event
        .tags
        .iter()
        .map(|tag| tag.as_slice().to_vec())
        .collect()
}

pub(super) fn forum_message_from_event(event: &nostr::Event, channel_id: &str) -> ForumMessageInfo {
    ForumMessageInfo {
        event_id: event.id.to_hex(),
        pubkey: event.pubkey.to_hex(),
        sig: event.sig.to_string(),
        content: event.content.clone(),
        kind: event.kind.as_u16() as u32,
        created_at: event.created_at.as_secs() as i64,
        channel_id: channel_id.to_string(),
        tags: tags_to_vec(event),
        thread_summary: Some(ThreadSummary {
            reply_count: 0,
            descendant_count: 0,
            last_reply_at: None,
            participants: Vec::new(),
        }),
        reactions: serde_json::Value::Null,
    }
}

/// Splits a forum posts response into posts and their reply summaries.
///
/// The head page comes from the relay's channel window, which adds one
/// kind:39005 thread summary per post with replies (keyed by its `e` tag) and
/// one kind:39006 window-bounds event. Only kind:45001 events become posts.
pub(super) fn split_forum_posts_response(
    events: Vec<nostr::Event>,
) -> (
    Vec<nostr::Event>,
    std::collections::HashMap<String, ThreadSummary>,
) {
    let mut posts = Vec::new();
    let mut summaries = std::collections::HashMap::new();
    for event in events {
        match event.kind.as_u16() as u32 {
            45001 => posts.push(event),
            buzz_core_pkg::kind::KIND_THREAD_SUMMARY => {
                let root = event.tags.iter().find_map(|tag| match tag.as_slice() {
                    [name, value, ..] if name.as_str() == "e" => Some(value.clone()),
                    _ => None,
                });
                let summary = serde_json::from_str::<ThreadSummary>(&event.content);
                if let (Some(root), Ok(summary)) = (root, summary) {
                    summaries.insert(root, summary);
                }
            }
            _ => {}
        }
    }
    (posts, summaries)
}

/// Channel-window filter whose first page starts at a forum post, so the relay
/// returns that post with its thread summary.
///
/// The window orders rows `created_at DESC, id ASC`, and a `(until, before_id)`
/// cursor selects `created_at < until OR (created_at = until AND id > before_id)`.
/// An all-zero `before_id` therefore keeps every post from the post's own
/// second, the post included. The small page absorbs other posts from that
/// same second.
pub(super) fn forum_post_summary_filter(
    channel_id: &str,
    post_created_at: i64,
) -> serde_json::Value {
    serde_json::json!({
        "kinds": [45001],
        "#h": [channel_id],
        "limit": 10,
        "until": post_created_at,
        "before_id": "0".repeat(64),
        "top_level": true,
        "include_summaries": true,
    })
}

/// Replace a forum post's placeholder summary with the relay's summary for it
/// from a [`forum_post_summary_filter`] response. Leaves the post unchanged when
/// the response has no summary for it (no replies, or not in the page).
///
/// The open post needs the relay's `last_reply_at`: the relay stamps it with its
/// own clock when it stores a reply, so it can be later than the reply's
/// `created_at`. Marking the post read only at `created_at` would leave the
/// list's new-reply marker lit after the post was read.
pub(super) fn attach_post_summary(post: &mut ForumMessageInfo, window_events: Vec<nostr::Event>) {
    let (_, mut summaries) = split_forum_posts_response(window_events);
    if let Some(summary) = summaries.remove(&post.event_id) {
        post.thread_summary = Some(summary);
    }
}

pub(super) fn forum_reply_from_event(
    event: &nostr::Event,
    channel_id: &str,
    root_event_id: &str,
) -> ForumThreadReplyInfo {
    let (mut parent_id, mut explicit_root) = (None, None);
    for tag in event.tags.iter() {
        let values = tag.as_slice();
        if values.len() >= 2 && values[0] == "e" {
            match values.get(3).map(String::as_str) {
                Some("root") => explicit_root = Some(values[1].clone()),
                Some("reply") => parent_id = Some(values[1].clone()),
                _ if parent_id.is_none() => parent_id = Some(values[1].clone()),
                _ => {}
            }
        }
    }

    let parent = parent_id
        .clone()
        .unwrap_or_else(|| root_event_id.to_string());
    let root = explicit_root.unwrap_or_else(|| root_event_id.to_string());
    let depth = if parent == root { 1 } else { 2 };

    ForumThreadReplyInfo {
        event_id: event.id.to_hex(),
        pubkey: event.pubkey.to_hex(),
        sig: event.sig.to_string(),
        content: event.content.clone(),
        kind: event.kind.as_u16() as u32,
        created_at: event.created_at.as_secs() as i64,
        channel_id: channel_id.to_string(),
        tags: tags_to_vec(event),
        parent_event_id: Some(parent),
        root_event_id: Some(root),
        depth,
        broadcast: false,
        reactions: serde_json::Value::Null,
    }
}

pub(super) fn link_preview_suppression_targets(
    originals: &[nostr::Event],
    edits: &[nostr::Event],
    owner_pubkeys: &std::collections::HashMap<String, String>,
) -> std::collections::HashSet<String> {
    let originals_by_id = originals
        .iter()
        .map(|event| (event.id.to_hex(), event))
        .collect::<std::collections::HashMap<_, _>>();

    edits
        .iter()
        .filter(|event| {
            event.kind.as_u16() == 40003
                && event
                    .tags
                    .iter()
                    .any(|tag| tag.as_slice() == ["link-preview".to_string(), "none".to_string()])
        })
        .filter_map(|edit| {
            let target_id = edit.tags.iter().find_map(|tag| {
                let values = tag.as_slice();
                (values.first().map(String::as_str) == Some("e"))
                    .then(|| values.get(1).cloned())
                    .flatten()
            })?;
            let target = originals_by_id.get(&target_id)?;
            let author = target.pubkey.to_hex();
            let signer = edit.pubkey.to_hex();
            (signer == author || owner_pubkeys.get(&author) == Some(&signer)).then_some(target_id)
        })
        .collect()
}

pub(super) fn apply_link_preview_suppression(
    tags: &mut Vec<Vec<String>>,
    event_id: &str,
    suppressed: &std::collections::HashSet<String>,
) {
    if suppressed.contains(event_id)
        && !tags
            .iter()
            .any(|tag| tag.as_slice() == ["link-preview".to_string(), "none".to_string()])
    {
        tags.push(vec!["link-preview".to_string(), "none".to_string()]);
    }
}

#[tauri::command]
pub async fn get_forum_posts(
    channel_id: String,
    limit: Option<u32>,
    before: Option<i64>,
    state: State<'_, AppState>,
) -> Result<ForumPostsResponse, String> {
    let cap = limit.unwrap_or(20).min(100);
    let mut filter = serde_json::Map::new();
    filter.insert("kinds".to_string(), serde_json::json!([45001]));
    filter.insert("#h".to_string(), serde_json::json!([channel_id.clone()]));
    filter.insert("limit".to_string(), serde_json::json!(cap));
    if let Some(t) = before {
        filter.insert("until".to_string(), serde_json::json!(t));
    } else {
        // The relay's channel window adds each post's reply count and last
        // reply time. Its cursor needs an event id as well as a timestamp,
        // so older pages keep the plain query without summaries.
        filter.insert("top_level".to_string(), serde_json::json!(true));
        filter.insert("include_summaries".to_string(), serde_json::json!(true));
    }

    let response = query_relay(&state, &[serde_json::Value::Object(filter)]).await?;
    let (events, mut summaries) = split_forum_posts_response(response);
    let ids = events
        .iter()
        .map(|event| event.id.to_hex())
        .collect::<Vec<_>>();
    let edits = if ids.is_empty() {
        Vec::new()
    } else {
        query_relay(
            &state,
            &[serde_json::json!({ "kinds": [40003], "#e": ids })],
        )
        .await
        .unwrap_or_default()
    };
    let owner_pubkeys = fetch_agent_owner_pubkeys(&state, &events).await;
    let suppressed = link_preview_suppression_targets(&events, &edits, &owner_pubkeys);
    let messages: Vec<ForumMessageInfo> = events
        .iter()
        .map(|ev| {
            let mut message = forum_message_from_event(ev, &channel_id);
            apply_link_preview_suppression(&mut message.tags, &message.event_id, &suppressed);
            if let Some(summary) = summaries.remove(&message.event_id) {
                message.thread_summary = Some(summary);
            }
            message
        })
        .collect();

    let next_cursor = messages.last().map(|m| m.created_at);
    Ok(ForumPostsResponse {
        messages,
        next_cursor,
    })
}

#[tauri::command]
pub async fn get_forum_thread(
    channel_id: String,
    event_id: String,
    limit: Option<u32>,
    cursor: Option<String>,
    state: State<'_, AppState>,
) -> Result<ForumThreadResponse, String> {
    let _ = (limit, cursor);
    // Two filters: the root event itself, plus any reply (kinds 9/45003)
    // that references it via #e.
    let events = query_relay(
        &state,
        &[
            serde_json::json!({ "ids": [event_id.clone()], "kinds": [9, 40002, 45001, 45003] }),
            serde_json::json!({
                "kinds": [9, 45003],
                "#e": [event_id.clone()],
                "#h": [channel_id.clone()],
            }),
        ],
    )
    .await?;
    let ids = events
        .iter()
        .map(|event| event.id.to_hex())
        .collect::<Vec<_>>();
    let edits = if ids.is_empty() {
        Vec::new()
    } else {
        query_relay(
            &state,
            &[serde_json::json!({ "kinds": [40003], "#e": ids })],
        )
        .await
        .unwrap_or_default()
    };
    let owner_pubkeys = fetch_agent_owner_pubkeys(&state, &events).await;
    let suppressed = link_preview_suppression_targets(&events, &edits, &owner_pubkeys);

    let mut root: Option<ForumMessageInfo> = None;
    let mut replies: Vec<ForumThreadReplyInfo> = Vec::new();
    for ev in &events {
        if ev.id.to_hex() == event_id {
            let mut message = forum_message_from_event(ev, &channel_id);
            apply_link_preview_suppression(&mut message.tags, &message.event_id, &suppressed);
            root = Some(message);
        } else if ev.kind.as_u16() as u32 != 40003 {
            let mut reply = forum_reply_from_event(ev, &channel_id, &event_id);
            apply_link_preview_suppression(&mut reply.tags, &reply.event_id, &suppressed);
            replies.push(reply);
        }
    }
    let total_replies = replies.len() as u32;

    let mut root = root.ok_or_else(|| "forum thread root event not found".to_string())?;
    if root.kind == 45001 {
        // Without the relay summary the post keeps its placeholder summary; the
        // only cost is a new-reply marker that can stay lit, so a failed
        // summary read must not fail opening the post.
        let window = query_relay(
            &state,
            &[forum_post_summary_filter(&channel_id, root.created_at)],
        )
        .await
        .unwrap_or_default();
        attach_post_summary(&mut root, window);
    }
    Ok(ForumThreadResponse {
        root,
        replies,
        total_replies,
        next_cursor: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use nostr::{EventBuilder, Keys, Kind};

    fn signed_event(keys: &Keys, kind: u16, tags: Vec<Vec<String>>) -> nostr::Event {
        let tags = tags
            .into_iter()
            .map(nostr::Tag::parse)
            .collect::<Result<Vec<_>, _>>()
            .expect("valid tags");
        EventBuilder::new(Kind::Custom(kind), "body")
            .tags(tags)
            .sign_with_keys(keys)
            .expect("event signs")
    }

    #[test]
    fn split_forum_posts_response_attaches_relay_summaries() {
        let author = Keys::generate();
        let relay = Keys::generate();
        let answered = signed_event(&author, 45001, Vec::new());
        let quiet = signed_event(&author, 45001, vec![vec!["t".into(), "quiet".into()]]);
        assert_ne!(answered.id, quiet.id);
        let answered_id = answered.id.to_hex();
        let bob = Keys::generate().public_key().to_hex();
        let summary = EventBuilder::new(
            Kind::Custom(39005),
            serde_json::json!({
                "reply_count": 2,
                "descendant_count": 3,
                "last_reply_at": 1_790_000_000,
                "participants": [bob],
            })
            .to_string(),
        )
        .tags([
            nostr::Tag::parse(["e", answered_id.as_str()]).expect("e tag"),
            nostr::Tag::parse(["d", answered_id.as_str()]).expect("d tag"),
        ])
        .sign_with_keys(&relay)
        .expect("summary signs");
        let bounds = signed_event(&relay, 39006, Vec::new());

        let (posts, summaries) =
            split_forum_posts_response(vec![answered, summary, quiet.clone(), bounds]);

        assert_eq!(posts.len(), 2);
        assert!(posts.iter().all(|post| post.kind.as_u16() == 45001));
        assert_eq!(summaries.len(), 1);
        let summary = &summaries[&answered_id];
        assert_eq!(summary.reply_count, 2);
        assert_eq!(summary.descendant_count, 3);
        assert_eq!(summary.last_reply_at, Some(1_790_000_000));
        assert_eq!(summary.participants, vec![bob]);
        assert!(!summaries.contains_key(&quiet.id.to_hex()));
    }

    #[test]
    fn forum_post_summary_filter_starts_the_window_at_the_post() {
        let filter = forum_post_summary_filter("chan", 1_790_000_123);
        assert_eq!(filter["kinds"], serde_json::json!([45001]));
        assert_eq!(filter["#h"], serde_json::json!(["chan"]));
        assert_eq!(filter["until"], serde_json::json!(1_790_000_123));
        assert_eq!(filter["before_id"], serde_json::json!("0".repeat(64)));
        assert_eq!(filter["top_level"], serde_json::json!(true));
        assert_eq!(filter["include_summaries"], serde_json::json!(true));
    }

    fn summary_event(relay: &Keys, root_id: &str, last_reply_at: i64) -> nostr::Event {
        EventBuilder::new(
            Kind::Custom(39005),
            serde_json::json!({
                "reply_count": 1,
                "descendant_count": 1,
                "last_reply_at": last_reply_at,
                "participants": [],
            })
            .to_string(),
        )
        .tags([
            nostr::Tag::parse(["e", root_id]).expect("e tag"),
            nostr::Tag::parse(["d", root_id]).expect("d tag"),
        ])
        .sign_with_keys(relay)
        .expect("summary signs")
    }

    #[test]
    fn attach_post_summary_takes_the_relay_summary_for_that_post_only() {
        let author = Keys::generate();
        let relay = Keys::generate();
        let post = signed_event(&author, 45001, Vec::new());
        let neighbour = signed_event(&author, 45001, vec![vec!["t".into(), "other".into()]]);
        let mut info = forum_message_from_event(&post, "chan");
        let window = vec![
            neighbour.clone(),
            summary_event(&relay, &neighbour.id.to_hex(), 1_600),
            post.clone(),
            summary_event(&relay, &post.id.to_hex(), 1_501),
        ];

        attach_post_summary(&mut info, window);

        let summary = info.thread_summary.expect("summary attached");
        assert_eq!(summary.reply_count, 1);
        assert_eq!(summary.last_reply_at, Some(1_501));
    }

    #[test]
    fn attach_post_summary_keeps_the_placeholder_without_a_summary() {
        let author = Keys::generate();
        let post = signed_event(&author, 45001, Vec::new());
        let mut info = forum_message_from_event(&post, "chan");

        attach_post_summary(&mut info, vec![post.clone()]);

        let summary = info.thread_summary.expect("placeholder kept");
        assert_eq!(summary.reply_count, 0);
        assert_eq!(summary.last_reply_at, None);
    }

    #[test]
    fn suppression_targets_accepts_author_and_verified_owner_only() {
        let author = Keys::generate();
        let owner = Keys::generate();
        let attacker = Keys::generate();
        let original = signed_event(&author, 9, Vec::new());
        let marker = vec!["link-preview".to_string(), "none".to_string()];
        let target = vec!["e".to_string(), original.id.to_hex()];
        let author_edit = signed_event(&author, 40003, vec![target.clone(), marker.clone()]);
        let owner_edit = signed_event(&owner, 40003, vec![target.clone(), marker.clone()]);
        let spoofed_edit = signed_event(&attacker, 40003, vec![target, marker]);
        let owners = std::collections::HashMap::from([(
            author.public_key().to_hex(),
            owner.public_key().to_hex(),
        )]);

        for edit in [&author_edit, &owner_edit] {
            assert!(link_preview_suppression_targets(
                std::slice::from_ref(&original),
                std::slice::from_ref(edit),
                &owners,
            )
            .contains(&original.id.to_hex()));
        }
        assert!(link_preview_suppression_targets(
            std::slice::from_ref(&original),
            std::slice::from_ref(&spoofed_edit),
            &owners,
        )
        .is_empty());
    }
}
