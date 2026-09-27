use super::*;
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};

use nostr::{EventBuilder, Keys, Kind, Tag, Timestamp};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::config::RespondTo;
use crate::filter::{ChannelScope, SubscriptionRule};
use crate::relay::ChannelInfo;
use crate::{
    authorize_normal_listener_event, AuthorizedNormalListenerEvent, InboundAuthorGate, OwnerCache,
};

fn message(
    author: &Keys,
    channel: Uuid,
    parent: Option<&Event>,
    mentions: &[&Keys],
    text: &str,
) -> Event {
    let mut tags = vec![Tag::parse(["h", &channel.to_string()]).unwrap()];
    if let Some(parent) = parent {
        let root = parse_thread_markers(&parent.tags)
            .resolve()
            .map(|(root, _)| root)
            .unwrap_or_else(|| parent.id.to_hex());
        tags.push(Tag::parse(["e", &root, "", "root"]).unwrap());
        tags.push(Tag::parse(["e", &parent.id.to_hex(), "", "reply"]).unwrap());
    }
    tags.extend(mentions.iter().map(|key| Tag::public_key(key.public_key())));
    EventBuilder::new(Kind::Custom(9), text)
        .tags(tags)
        .custom_created_at(Timestamp::from(100))
        .sign_with_keys(author)
        .unwrap()
}

struct Fixture {
    rest: RestClient,
    events: Arc<Mutex<Vec<Event>>>,
    queries: Arc<Mutex<Vec<Value>>>,
    server: tokio::task::JoinHandle<()>,
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.server.abort();
    }
}
impl Fixture {
    async fn new(events: Vec<Event>) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let events = Arc::new(Mutex::new(events));
        let queries = Arc::new(Mutex::new(Vec::new()));
        let data = events.clone();
        let log = queries.clone();
        let server = tokio::spawn(async move {
            loop {
                let (mut socket, _) = listener.accept().await.unwrap();
                let mut bytes = Vec::new();
                let (header_len, content_len) = loop {
                    let mut chunk = [0; 4096];
                    let n = socket.read(&mut chunk).await.unwrap();
                    assert!(n > 0);
                    bytes.extend_from_slice(&chunk[..n]);
                    if let Some(at) = bytes.windows(4).position(|w| w == b"\r\n\r\n") {
                        let header = String::from_utf8_lossy(&bytes[..at]);
                        let len = header
                            .lines()
                            .find_map(|line| {
                                line.to_ascii_lowercase()
                                    .strip_prefix("content-length: ")
                                    .and_then(|v| v.parse::<usize>().ok())
                            })
                            .unwrap_or(0);
                        break (at + 4, len);
                    }
                };
                while bytes.len() < header_len + content_len {
                    let mut chunk = [0; 4096];
                    let n = socket.read(&mut chunk).await.unwrap();
                    assert!(n > 0);
                    bytes.extend_from_slice(&chunk[..n]);
                }
                let body = if bytes.starts_with(b"GET ") {
                    json!({})
                } else {
                    let filters: Vec<Value> =
                        serde_json::from_slice(&bytes[header_len..header_len + content_len])
                            .unwrap();
                    let mut found = Vec::new();
                    for filter in filters {
                        log.lock().unwrap().push(filter.clone());
                        let mut matching: Vec<Event> = data
                            .lock()
                            .unwrap()
                            .iter()
                            .filter(|event| {
                                let encoded = serde_json::to_value(event).unwrap();
                                filter.as_object().unwrap().iter().all(|(key, value)| {
                                    match key.as_str() {
                                        "ids" => value.as_array().unwrap().contains(&encoded["id"]),
                                        "authors" => {
                                            value.as_array().unwrap().contains(&encoded["pubkey"])
                                        }
                                        "kinds" => {
                                            value.as_array().unwrap().contains(&encoded["kind"])
                                        }
                                        "until" => encoded["created_at"].as_u64() <= value.as_u64(),
                                        "before_id" => {
                                            encoded["created_at"] != filter["until"]
                                                || encoded["id"].as_str() < value.as_str()
                                        }
                                        k if k.starts_with('#') => event.tags.iter().any(|t| {
                                            let parts = t.as_slice();
                                            parts.first().is_some_and(|name| name == &k[1..])
                                                && parts.get(1).is_some_and(|v| {
                                                    value.as_array().unwrap().contains(&json!(v))
                                                })
                                        }),
                                        "limit" => true,
                                        other => panic!("unexpected query field {other}"),
                                    }
                                })
                            })
                            .cloned()
                            .collect();
                        matching.sort_by(|a, b| {
                            b.created_at
                                .cmp(&a.created_at)
                                .then_with(|| b.id.cmp(&a.id))
                        });
                        matching.truncate(filter["limit"].as_u64().unwrap_or(500) as usize);
                        found.extend(matching);
                    }
                    json!(found)
                }
                .to_string();
                let response = format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", body.len(), body);
                socket.write_all(response.as_bytes()).await.unwrap();
            }
        });
        Self {
            rest: RestClient {
                http: reqwest::Client::new(),
                base_url: format!("http://{address}"),
                keys: Keys::generate(),
                auth_tag_json: None,
            },
            events,
            queries,
            server,
        }
    }

    // Exercise the production author gate AND subscription/recipient boundary.
    // A new gate/resolver each time deliberately simulates process restarts.
    async fn admit(
        &self,
        event: Event,
        channel: Uuid,
        agent: &Keys,
        owner: &Keys,
        policy: RecipientPolicy,
        respond_to: RespondTo,
    ) -> bool {
        let owner_hex = owner.public_key().to_hex();
        let agent_hex = agent.public_key().to_hex();
        let channels = ChannelInfoResolver::new(
            HashMap::from([(
                channel,
                ChannelInfo {
                    name: "routing".into(),
                    channel_type: "stream".into(),
                    description: None,
                },
            )]),
            self.rest.clone(),
        );
        let mut gate = InboundAuthorGate::connect(&self.rest, &agent_hex, "recipient-test").await;
        let cache = OwnerCache::new(Some(owner_hex.clone()));
        let rules = vec![SubscriptionRule {
            name: "mentions".into(),
            channels: ChannelScope::List(vec![channel.to_string()]),
            kinds: vec![9, 45001, 45003],
            require_mention: true,
            filter: None,
            compiled_filter: None,
            consecutive_timeouts: Default::default(),
            prompt_tag: None,
        }];
        let Some(authorized) = authorize_normal_listener_event(
            &mut gate,
            BuzzEvent {
                channel_id: channel,
                event,
                connection_generation: 0,
            },
            &respond_to,
            &HashSet::new(),
            &cache,
            &channels,
            &self.rest,
        )
        .await
        else {
            return false;
        };
        AuthorizedNormalListenerEvent(authorized)
            .match_subscription(
                &rules,
                &agent_hex,
                &RoutingContext {
                    policy,
                    rest: &self.rest,
                    channels: &channels,
                    owner: Some(&owner_hex),
                },
            )
            .await
            .is_some()
    }
}

#[tokio::test]
async fn roots_and_explicit_mentions_follow_precedence_at_ingress() {
    let (owner, agent, other) = (Keys::generate(), Keys::generate(), Keys::generate());
    let channel = Uuid::new_v4();
    let fixture = Fixture::new(vec![]).await;
    for (mentions, expected) in [
        (vec![], true),
        (vec![&agent], true),
        (vec![&other], false),
        (vec![&agent, &other], true),
    ] {
        let event = message(&owner, channel, None, &mentions, "root");
        assert_eq!(
            fixture
                .admit(
                    event,
                    channel,
                    &agent,
                    &owner,
                    RecipientPolicy::Conversation,
                    RespondTo::OwnerOnly
                )
                .await,
            expected
        );
    }
    let event = message(&owner, channel, None, &[], "legacy");
    assert!(
        !fixture
            .admit(
                event,
                channel,
                &agent,
                &owner,
                RecipientPolicy::Legacy,
                RespondTo::OwnerOnly
            )
            .await
    );
    assert!(fixture.queries.lock().unwrap().is_empty());
}

#[tokio::test]
async fn thread_invitation_survives_restart_and_targeted_reply_does_not_remove_it() {
    let (owner, agent, other) = (Keys::generate(), Keys::generate(), Keys::generate());
    let channel = Uuid::new_v4();
    let root = message(&owner, channel, None, &[], "root");
    let invitation = message(&owner, channel, Some(&root), &[&agent], "join");
    let targeted = message(&owner, channel, Some(&root), &[&other], "only other");
    let followup = message(&owner, channel, Some(&targeted), &[], "nested followup");
    let fixture = Fixture::new(vec![root, invitation, targeted.clone()]).await;
    assert!(
        !fixture
            .admit(
                targeted,
                channel,
                &agent,
                &owner,
                RecipientPolicy::Conversation,
                RespondTo::OwnerOnly
            )
            .await
    );
    assert!(
        fixture
            .admit(
                followup.clone(),
                channel,
                &agent,
                &owner,
                RecipientPolicy::Conversation,
                RespondTo::OwnerOnly
            )
            .await
    );
    assert!(
        fixture
            .admit(
                followup,
                channel,
                &agent,
                &owner,
                RecipientPolicy::Conversation,
                RespondTo::OwnerOnly
            )
            .await
    );
    for query in fixture.queries.lock().unwrap().iter() {
        assert_eq!(query["#h"], json!([channel.to_string()]));
    }
}

#[tokio::test]
async fn receiving_broadcast_alone_does_not_join_a_thread() {
    let (owner, agent) = (Keys::generate(), Keys::generate());
    let channel = Uuid::new_v4();
    let root = message(&owner, channel, None, &[], "broadcast");
    let reply = message(&owner, channel, Some(&root), &[], "followup");
    let fixture = Fixture::new(vec![root.clone()]).await;
    assert!(
        fixture
            .admit(
                root,
                channel,
                &agent,
                &owner,
                RecipientPolicy::Conversation,
                RespondTo::OwnerOnly
            )
            .await
    );
    assert!(
        !fixture
            .admit(
                reply,
                channel,
                &agent,
                &owner,
                RecipientPolicy::Conversation,
                RespondTo::OwnerOnly
            )
            .await
    );
}

#[tokio::test]
async fn root_author_and_prior_reply_author_are_participants() {
    let (owner, agent) = (Keys::generate(), Keys::generate());
    let channel = Uuid::new_v4();
    for authored_root in [true, false] {
        let root = message(
            if authored_root { &agent } else { &owner },
            channel,
            None,
            &[],
            "root",
        );
        let own_reply = message(&agent, channel, Some(&root), &[], "answer");
        let reply = message(&owner, channel, Some(&root), &[], "continue");
        let fixture = Fixture::new(vec![root, own_reply]).await;
        assert!(
            fixture
                .admit(
                    reply,
                    channel,
                    &agent,
                    &owner,
                    RecipientPolicy::Conversation,
                    RespondTo::OwnerOnly
                )
                .await
        );
    }
}

#[tokio::test]
async fn authorization_remains_required_even_with_an_explicit_mention() {
    let (owner, agent) = (Keys::generate(), Keys::generate());
    let channel = Uuid::new_v4();
    let event = message(&owner, channel, None, &[&agent], "wake");
    let fixture = Fixture::new(vec![]).await;
    assert!(
        !fixture
            .admit(
                event,
                channel,
                &agent,
                &owner,
                RecipientPolicy::Conversation,
                RespondTo::Nobody
            )
            .await
    );
}

#[tokio::test]
async fn agent_attestations_and_bot_profiles_prevent_implicit_loops() {
    let (owner, agent, bot) = (Keys::generate(), Keys::generate(), Keys::generate());
    let channel = Uuid::new_v4();
    let profile = EventBuilder::new(Kind::Metadata, r#"{"bot":true}"#)
        .sign_with_keys(&bot)
        .unwrap();
    let fixture = Fixture::new(vec![profile]).await;
    let event = message(&bot, channel, None, &[], "bot reply");
    assert!(
        !fixture
            .admit(
                event,
                channel,
                &agent,
                &owner,
                RecipientPolicy::Conversation,
                RespondTo::Anyone
            )
            .await
    );
    let explicit = message(&bot, channel, None, &[&agent], "delegation");
    assert!(
        fixture
            .admit(
                explicit,
                channel,
                &agent,
                &owner,
                RecipientPolicy::Conversation,
                RespondTo::Anyone
            )
            .await
    );
    let attested = EventBuilder::new(Kind::Custom(9), "attested bot")
        .tags([
            Tag::parse(["h", &channel.to_string()]).unwrap(),
            Tag::parse(["auth", "present"]).unwrap(),
        ])
        .sign_with_keys(&bot)
        .unwrap();
    fixture.events.lock().unwrap().clear();
    assert!(
        !fixture
            .admit(
                attested,
                channel,
                &agent,
                &owner,
                RecipientPolicy::Conversation,
                RespondTo::Anyone
            )
            .await
    );
}

#[tokio::test]
async fn missing_root_fails_closed_but_explicit_mention_still_works() {
    let (owner, agent) = (Keys::generate(), Keys::generate());
    let channel = Uuid::new_v4();
    let root = message(&owner, channel, None, &[&agent], "missing root");
    let fixture = Fixture::new(vec![]).await;
    for (mentions, expected) in [(vec![], false), (vec![&agent], true)] {
        let reply = message(&owner, channel, Some(&root), &mentions, "reply");
        assert_eq!(
            fixture
                .admit(
                    reply,
                    channel,
                    &agent,
                    &owner,
                    RecipientPolicy::Conversation,
                    RespondTo::OwnerOnly
                )
                .await,
            expected
        );
    }
}

#[tokio::test]
async fn quote_tags_and_other_channels_do_not_create_participation() {
    let (owner, agent) = (Keys::generate(), Keys::generate());
    let channel = Uuid::new_v4();
    let root = message(&owner, channel, None, &[], "root");
    let quote = EventBuilder::new(Kind::Custom(9), "quoted root")
        .tags([
            Tag::parse(["h", &channel.to_string()]).unwrap(),
            Tag::parse(["e", &root.id.to_hex(), "", "mention"]).unwrap(),
            Tag::public_key(agent.public_key()),
        ])
        .custom_created_at(Timestamp::from(100))
        .sign_with_keys(&owner)
        .unwrap();
    let elsewhere = message(
        &owner,
        Uuid::new_v4(),
        Some(&root),
        &[&agent],
        "another channel",
    );
    let reply = message(&owner, channel, Some(&root), &[], "reply");
    let fixture = Fixture::new(vec![root, quote, elsewhere]).await;
    assert!(
        !fixture
            .admit(
                reply,
                channel,
                &agent,
                &owner,
                RecipientPolicy::Conversation,
                RespondTo::OwnerOnly
            )
            .await
    );
}

#[tokio::test]
async fn participation_beyond_a_full_same_second_page_is_recovered() {
    let (owner, agent) = (Keys::generate(), Keys::generate());
    let channel = Uuid::new_v4();
    let root = message(&owner, channel, None, &[], "root");
    let mut events = vec![root.clone()];
    // A full page of quotes mentions the agent but does not join this thread.
    for i in 0..501 {
        events.push(
            EventBuilder::new(Kind::Custom(9), format!("quote {i}"))
                .tags([
                    Tag::parse(["h", &channel.to_string()]).unwrap(),
                    Tag::parse(["e", &root.id.to_hex(), "", "mention"]).unwrap(),
                    Tag::public_key(agent.public_key()),
                ])
                .custom_created_at(Timestamp::from(200))
                .sign_with_keys(&owner)
                .unwrap(),
        );
    }
    events.push(message(
        &owner,
        channel,
        Some(&root),
        &[&agent],
        "old invitation",
    ));
    let reply = EventBuilder::new(Kind::Custom(9), "reply")
        .tags([
            Tag::parse(["h", &channel.to_string()]).unwrap(),
            Tag::parse(["e", &root.id.to_hex(), "", "reply"]).unwrap(),
        ])
        .custom_created_at(Timestamp::from(300))
        .sign_with_keys(&owner)
        .unwrap();
    let fixture = Fixture::new(events).await;
    assert!(
        fixture
            .admit(
                reply,
                channel,
                &agent,
                &owner,
                RecipientPolicy::Conversation,
                RespondTo::OwnerOnly
            )
            .await
    );
    assert!(fixture
        .queries
        .lock()
        .unwrap()
        .iter()
        .any(|query| query.get("before_id").is_some()));
}

#[tokio::test]
async fn self_events_never_wake_even_when_explicitly_addressed() {
    let agent = Keys::generate();
    let channel = Uuid::new_v4();
    let event = message(&agent, channel, None, &[&agent], "self");
    let fixture = Fixture::new(vec![]).await;
    assert!(
        !fixture
            .admit(
                event,
                channel,
                &agent,
                &agent,
                RecipientPolicy::Conversation,
                RespondTo::Anyone
            )
            .await
    );
}

#[tokio::test]
async fn forum_comment_uses_the_same_participation_rules() {
    let (owner, agent) = (Keys::generate(), Keys::generate());
    let channel = Uuid::new_v4();
    let root = EventBuilder::new(Kind::Custom(45001), "forum post")
        .tags([
            Tag::parse(["h", &channel.to_string()]).unwrap(),
            Tag::public_key(agent.public_key()),
        ])
        .custom_created_at(Timestamp::from(90))
        .sign_with_keys(&owner)
        .unwrap();
    let comment = EventBuilder::new(Kind::Custom(45003), "forum comment")
        .tags([
            Tag::parse(["h", &channel.to_string()]).unwrap(),
            Tag::parse(["e", &root.id.to_hex(), "", "reply"]).unwrap(),
        ])
        .custom_created_at(Timestamp::from(100))
        .sign_with_keys(&owner)
        .unwrap();
    let fixture = Fixture::new(vec![root]).await;
    assert!(
        fixture
            .admit(
                comment,
                channel,
                &agent,
                &owner,
                RecipientPolicy::Conversation,
                RespondTo::OwnerOnly
            )
            .await
    );
}

#[tokio::test]
async fn expression_filters_dm_filters_and_nonchat_filters_remain_in_force() {
    let (owner, agent) = (Keys::generate(), Keys::generate());
    let channel = Uuid::new_v4();
    let fixture = Fixture::new(vec![]).await;
    let agent_hex = agent.public_key().to_hex();
    let owner_hex = owner.public_key().to_hex();
    for (channel_type, kind, expression, expected) in [
        ("stream", 9, Some("false"), false),
        ("stream", 9, Some("true"), true),
        ("stream", 40002, None, true),
        ("stream", 9, Some("unknown_variable"), false),
        ("dm", 9, None, false),
        ("stream", 46010, None, false),
    ] {
        let channels = ChannelInfoResolver::new(
            HashMap::from([(
                channel,
                ChannelInfo {
                    name: "test".into(),
                    channel_type: channel_type.into(),
                    description: None,
                },
            )]),
            fixture.rest.clone(),
        );
        let context = RoutingContext {
            policy: RecipientPolicy::Conversation,
            rest: &fixture.rest,
            channels: &channels,
            owner: Some(&owner_hex),
        };
        let rule = SubscriptionRule {
            name: "guarded".into(),
            channels: ChannelScope::All("all".into()),
            kinds: vec![],
            require_mention: true,
            filter: expression.map(String::from),
            prompt_tag: None,
            compiled_filter: None,
            consecutive_timeouts: Default::default(),
        };
        let event = EventBuilder::new(Kind::Custom(kind), "test")
            .tags([Tag::parse(["h", &channel.to_string()]).unwrap()])
            .sign_with_keys(&owner)
            .unwrap();
        assert_eq!(
            context
                .match_subscription(
                    &BuzzEvent {
                        channel_id: channel,
                        event,
                        connection_generation: 0
                    },
                    &[rule],
                    &agent_hex
                )
                .await
                .is_some(),
            expected
        );
    }
}

#[tokio::test]
async fn missing_profile_or_network_failure_does_not_fall_back_to_broadcast() {
    let (owner, agent, unknown) = (Keys::generate(), Keys::generate(), Keys::generate());
    let channel = Uuid::new_v4();
    let fixture = Fixture::new(vec![]).await;
    let event = message(&unknown, channel, None, &[], "unknown");
    assert!(
        !fixture
            .admit(
                event,
                channel,
                &agent,
                &owner,
                RecipientPolicy::Conversation,
                RespondTo::Anyone
            )
            .await
    );
    let root = message(&owner, channel, None, &[], "root");
    let reply = message(&owner, channel, Some(&root), &[], "network failure");
    let offline = RestClient {
        base_url: "http://127.0.0.1:1".into(),
        ..fixture.rest.clone()
    };
    assert!(accepts(
        &BuzzEvent {
            channel_id: channel,
            event: reply,
            connection_generation: 0
        },
        &agent.public_key().to_hex(),
        Some(&owner.public_key().to_hex()),
        &offline
    )
    .await
    .is_err());
}
