import * as React from "react";

import { useAppShell } from "@/app/AppShellContext";
import { resolveMessageManagePermissions } from "@/features/messages/lib/messageDeleteAuthority";
import { useCanModerateChannelMessages } from "@/features/messages/lib/useCanModerateChannelMessages";
import { useProfileQuery, useUsersBatchQuery } from "@/features/profile/hooks";
import { mergeCurrentProfileIntoLookup } from "@/features/profile/lib/identity";
import type { TypingIndicatorEntry } from "@/features/messages/useChannelTyping";
import { getMentionTagPubkey } from "@/shared/lib/resolveMentionNames";
import type { Channel } from "@/shared/api/types";

import {
  useCreateForumPostMutation,
  useCreateForumReplyMutation,
  useDeleteForumPostMutation,
  useDeleteForumReplyMutation,
  useForumPostsQuery,
  useForumThreadQuery,
} from "../hooks";
import {
  groupForumTypingByPost,
  hasUnreadForumReplies,
  latestForumThreadActivityAt,
} from "../lib/forumActivity";
import { sortForumOldestFirst } from "../lib/forumOrder";
import { ForumPostCard } from "./ForumPostCard";
import { ForumPostList } from "./ForumPostList";
import { ForumThreadPanel } from "./ForumThreadPanel";

type ForumViewProps = {
  channel: Channel;
  /**
   * The forum's read marker as it stood when the channel was opened, before
   * opening it advanced the marker. Baseline for posts never opened.
   */
  channelOpenReadAt?: number | null;
  currentPubkey?: string;
  onClosePost: () => void;
  onSelectPost: (postId: string) => void;
  onTargetReached?: (messageId: string) => void;
  selectedPostId: string | null;
  targetReplyId: string | null;
  targetSearchMessageId?: string;
  targetSearchQuery?: string;
  typingEntries?: TypingIndicatorEntry[];
};

const EMPTY_TYPING_ENTRIES: TypingIndicatorEntry[] = [];

export function ForumView({
  channel,
  channelOpenReadAt = null,
  currentPubkey,
  onClosePost,
  onSelectPost,
  onTargetReached,
  selectedPostId,
  targetReplyId,
  targetSearchMessageId,
  targetSearchQuery,
  typingEntries = EMPTY_TYPING_ENTRIES,
}: ForumViewProps) {
  const [isComposerOpen, setIsComposerOpen] = React.useState(false);
  const { getThreadReadAt, markThreadRead, readStateVersion } = useAppShell();

  const profileQuery = useProfileQuery();
  const postsQuery = useForumPostsQuery(channel);
  const threadQuery = useForumThreadQuery(
    selectedPostId ? channel.id : null,
    selectedPostId,
  );
  const createPostMutation = useCreateForumPostMutation(channel);
  const createReplyMutation = useCreateForumReplyMutation(channel);
  const deletePostMutation = useDeleteForumPostMutation(channel);
  const deleteReplyMutation = useDeleteForumReplyMutation(
    channel,
    selectedPostId,
  );

  const postsData = postsQuery.data?.posts;
  const posts = React.useMemo(
    () => sortForumOldestFirst(postsData ?? []),
    [postsData],
  );
  const typingGroups = React.useMemo(
    () => groupForumTypingByPost(typingEntries),
    [typingEntries],
  );

  // readStateVersion changes whenever a read marker moves; recompute then.
  // biome-ignore lint/correctness/useExhaustiveDependencies: readStateVersion invalidates getThreadReadAt results
  const unreadPostIds = React.useMemo(() => {
    const ids = new Set<string>();
    for (const post of posts) {
      if (
        hasUnreadForumReplies({
          lastReplyAt: post.threadSummary?.lastReplyAt,
          threadReadAt: getThreadReadAt(post.eventId),
          channelBaselineAt: channelOpenReadAt,
        })
      ) {
        ids.add(post.eventId);
      }
    }
    return ids;
  }, [channelOpenReadAt, getThreadReadAt, posts, readStateVersion]);

  // Opening a post marks it read up to the newest activity it shows, and keeps
  // doing so while it stays open (new replies, including the viewer's own).
  const selectedThread = threadQuery.data;
  const selectedListSummary = selectedPostId
    ? (posts.find((post) => post.eventId === selectedPostId)?.threadSummary ??
      null)
    : null;
  React.useEffect(() => {
    if (
      !selectedPostId ||
      !selectedThread ||
      selectedThread.post.eventId !== selectedPostId
    ) {
      return;
    }
    const latest = latestForumThreadActivityAt(
      selectedThread,
      selectedListSummary,
    );
    const threadReadAt = getThreadReadAt(selectedPostId);
    if (threadReadAt !== null && threadReadAt >= latest) {
      return;
    }
    markThreadRead(selectedPostId, latest);
  }, [
    getThreadReadAt,
    markThreadRead,
    selectedListSummary,
    selectedPostId,
    selectedThread,
  ]);

  // Collect all pubkeys from posts and thread for profile resolution.
  // Mentioned pubkeys (`p`/`mention` tags) must be included too: mention
  // chips resolve names from this same lookup, and a mentioned user who
  // never authored a post would otherwise render as a dead chip.
  const allPubkeys = React.useMemo(() => {
    const pubkeys = new Set<string>();
    const addMentionPubkeys = (tags?: string[][]) => {
      for (const tag of tags ?? []) {
        const pubkey = getMentionTagPubkey(tag);
        if (pubkey) {
          pubkeys.add(pubkey);
        }
      }
    };
    for (const entry of typingEntries) {
      pubkeys.add(entry.pubkey);
    }
    for (const post of posts) {
      pubkeys.add(post.pubkey);
      addMentionPubkeys(post.tags);
      if (post.threadSummary?.participants) {
        for (const pk of post.threadSummary.participants) {
          pubkeys.add(pk);
        }
      }
    }
    if (threadQuery.data) {
      pubkeys.add(threadQuery.data.post.pubkey);
      addMentionPubkeys(threadQuery.data.post.tags);
      for (const reply of threadQuery.data.replies) {
        pubkeys.add(reply.pubkey);
        addMentionPubkeys(reply.tags);
      }
    }
    return [...pubkeys];
  }, [posts, threadQuery.data, typingEntries]);

  const profilesQuery = useUsersBatchQuery(allPubkeys, {
    enabled: allPubkeys.length > 0,
  });
  const effectiveCurrentPubkey = currentPubkey ?? profileQuery.data?.pubkey;
  const profiles = React.useMemo(
    () =>
      mergeCurrentProfileIntoLookup(
        profilesQuery.data?.profiles,
        profileQuery.data,
      ),
    [profileQuery.data, profilesQuery.data?.profiles],
  );

  // The relay refuses moderator deletes in an archived channel, so don't
  // offer one there (the timeline and Inbox hide Delete on archive, too).
  const canModerate =
    useCanModerateChannelMessages(channel.id) && channel.archivedAt === null;
  // Same delete rule as every other message surface: the author path (kind:5)
  // for your own or your agent's posts, the moderator path (kind:9005) for
  // anyone else's when you own/admin the community or this forum.
  const postDeleteAuthority = (post: { kind: number; pubkey: string }) =>
    resolveMessageManagePermissions(
      post,
      effectiveCurrentPubkey,
      profiles,
      canModerate,
    ).deleteAuthority;

  const previousChannelIdRef = React.useRef(channel.id);
  React.useEffect(() => {
    if (previousChannelIdRef.current === channel.id) {
      return;
    }

    previousChannelIdRef.current = channel.id;
    setIsComposerOpen(false);
  }, [channel.id]);

  if (selectedPostId) {
    const threadPost = threadQuery.data?.post;
    const expandedPostDeleteAuthority = threadPost
      ? postDeleteAuthority(threadPost)
      : null;

    return (
      <ForumThreadPanel
        key={`${channel.id}:${selectedPostId}`}
        postId={selectedPostId}
        canDeletePost={expandedPostDeleteAuthority !== null}
        canModerate={canModerate}
        currentPubkey={effectiveCurrentPubkey}
        isDeletingPost={deletePostMutation.isPending}
        isLoading={threadQuery.isLoading}
        isSendingReply={createReplyMutation.isPending}
        onBack={onClosePost}
        onDeletePost={(eventId) => {
          deletePostMutation.mutate(
            {
              eventId,
              asModerator: expandedPostDeleteAuthority === "moderator",
            },
            { onSuccess: onClosePost },
          );
        }}
        onDeleteReply={(eventId, { asModerator }) => {
          deleteReplyMutation.mutate({ eventId, asModerator });
        }}
        channelId={channel.id}
        onReply={(content, mentionPubkeys, mediaTags) =>
          createReplyMutation.mutateAsync({
            content,
            parentEventId: selectedPostId,
            mentionPubkeys,
            mediaTags,
          })
        }
        onTargetReached={onTargetReached}
        profiles={profiles}
        targetEventId={targetReplyId}
        targetSearchMessageId={targetSearchMessageId}
        targetSearchQuery={targetSearchQuery}
        thread={threadQuery.data}
        typingPubkeys={typingGroups.byPostId.get(selectedPostId)}
      />
    );
  }

  return (
    <ForumPostList
      channel={channel}
      channelTypingPubkeys={typingGroups.channelLevel}
      currentPubkey={effectiveCurrentPubkey}
      isComposerOpen={isComposerOpen}
      isCreatingPost={createPostMutation.isPending}
      isLoading={postsQuery.isLoading}
      key={channel.id}
      onComposerOpenChange={setIsComposerOpen}
      onCreatePost={(content, mentionPubkeys, mediaTags) =>
        createPostMutation.mutateAsync({ content, mentionPubkeys, mediaTags })
      }
      posts={posts}
      profiles={profiles}
      renderPost={(post) => {
        const deleteAuthority = postDeleteAuthority(post);
        return (
          <ForumPostCard
            canDelete={deleteAuthority !== null}
            currentPubkey={effectiveCurrentPubkey}
            hasUnreadReplies={unreadPostIds.has(post.eventId)}
            isActive={selectedPostId === post.eventId}
            isDeleting={
              deletePostMutation.isPending &&
              deletePostMutation.variables?.eventId === post.eventId
            }
            onClick={() => onSelectPost(post.eventId)}
            onDelete={(eventId) => {
              deletePostMutation.mutate({
                eventId,
                asModerator: deleteAuthority === "moderator",
              });
            }}
            post={post}
            profiles={profiles}
            typingPubkeys={typingGroups.byPostId.get(post.eventId)}
          />
        );
      }}
    />
  );
}
