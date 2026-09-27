import { ArrowLeft, MessageSquare } from "lucide-react";
import * as React from "react";

import { resolveMessageManagePermissions } from "@/features/messages/lib/messageDeleteAuthority";
import { handleTimelineMentionCopy } from "@/features/messages/lib/timelineMentionCopy";
import {
  resolveUserLabel,
  type UserProfileLookup,
} from "@/features/profile/lib/identity";
import { UserProfilePopover } from "@/features/profile/ui/UserProfilePopover";
import { UserAvatar } from "@/shared/ui/UserAvatar";
import type { ForumThreadResponse, ThreadReply } from "@/shared/api/types";
import { channelChrome } from "@/shared/layout/chromeLayout";
import { cn } from "@/shared/lib/cn";
import { useChannelNavigation } from "@/shared/context/ChannelNavigationContext";
import { resolveMentionProps } from "@/shared/lib/resolveMentionNames";
import { Button } from "@/shared/ui/button";
import { parseImetaTags } from "@/shared/ui/markdown/parseImeta";
import { Markdown } from "@/shared/ui/markdown";
import { hasLinkPreviewSuppression } from "@/features/messages/lib/formatTimelineMessages";
import { TypingIndicatorRow } from "@/features/messages/ui/TypingIndicatorRow";
import { useAnchoredScroll } from "@/features/messages/ui/useAnchoredScroll";
import { Skeleton } from "@/shared/ui/skeleton";
import { UnreadPill, unreadCountLabel } from "@/shared/ui/UnreadPill";

import { sortForumOldestFirst } from "../lib/forumOrder";
import { formatRelativeTime } from "../lib/time";
import { DeleteActionMenu } from "./DeleteActionMenu";
import { ForumComposer } from "./ForumComposer";

type ForumThreadPanelProps = {
  thread: ForumThreadResponse | undefined;
  isLoading: boolean;
  isSendingReply: boolean;
  channelId: string;
  postId: string;
  currentPubkey?: string;
  profiles?: UserProfileLookup;
  typingPubkeys?: string[];
  onBack: () => void;
  onReply: (
    content: string,
    mentionPubkeys: string[],
    mediaTags?: string[][],
  ) => undefined | Promise<unknown>;
  onDeletePost?: (eventId: string) => void;
  onDeleteReply?: (eventId: string, options: { asModerator: boolean }) => void;
  onTargetReached?: (eventId: string) => void;
  canDeletePost?: boolean;
  /** Viewer owns/admins the community or this forum: may delete any reply. */
  canModerate?: boolean;
  isDeletingPost?: boolean;
  targetEventId?: string | null;
  targetSearchMessageId?: string;
  targetSearchQuery?: string;
};

function ReplyRow({
  reply,
  canModerate = false,
  currentPubkey,
  profiles,
  channelNames,
  onDelete,
  searchQuery,
}: {
  reply: ThreadReply;
  canModerate?: boolean;
  currentPubkey?: string;
  profiles?: UserProfileLookup;
  channelNames?: string[];
  onDelete?: (eventId: string, options: { asModerator: boolean }) => void;
  searchQuery?: string;
}) {
  const replyAuthorLabel = resolveUserLabel({
    pubkey: reply.pubkey,
    currentPubkey,
    profiles,
    preferResolvedSelfLabel: true,
  });
  const replyAvatarUrl =
    profiles?.[reply.pubkey.toLowerCase()]?.avatarUrl ?? null;
  const replyAuthorIsAgent =
    profiles?.[reply.pubkey.toLowerCase()]?.isAgent === true;
  const { deleteAuthority } = resolveMessageManagePermissions(
    reply,
    currentPubkey,
    profiles,
    canModerate,
  );
  const showDelete = onDelete && deleteAuthority !== null;
  const {
    mentionNames: replyMentionNames,
    mentionPubkeysByName: replyMentionPubkeysByName,
  } = resolveMentionProps(reply.tags, profiles, reply.content);

  return (
    <div
      className="group content-visibility-auto px-4 py-3"
      data-forum-event-id={reply.eventId}
      data-message-id={reply.eventId}
    >
      <div className="flex items-center gap-2">
        <UserProfilePopover
          pubkey={reply.pubkey}
          role={replyAuthorIsAgent ? "bot" : undefined}
        >
          <button
            className="flex items-center gap-2 rounded-lg focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-ring"
            type="button"
          >
            <UserAvatar
              accent={replyAuthorIsAgent}
              avatarUrl={replyAvatarUrl}
              displayName={replyAuthorLabel}
              shape={replyAuthorIsAgent ? "squircle" : "circle"}
              size="sm"
            />
            <span className="text-sm font-medium text-foreground hover:underline">
              {replyAuthorLabel}
            </span>
          </button>
        </UserProfilePopover>
        <span className="text-xs text-muted-foreground">
          {formatRelativeTime(reply.createdAt)}
        </span>

        {showDelete ? (
          <DeleteActionMenu
            iconSize="sm"
            label="reply"
            onConfirm={() =>
              onDelete(reply.eventId, {
                asModerator: deleteAuthority === "moderator",
              })
            }
          />
        ) : null}
      </div>
      <div className="mt-1.5 pl-8">
        <Markdown
          channelNames={channelNames}
          className="text-sm"
          content={reply.content}
          messageId={reply.eventId}
          linkPreviewsSuppressed={hasLinkPreviewSuppression(reply.tags)}
          linkPreviewTags={reply.tags}
          imetaByUrl={parseImetaTags(reply.tags)}
          mentionNames={replyMentionNames}
          mentionPubkeysByName={replyMentionPubkeysByName}
          searchQuery={searchQuery}
        />
      </div>
    </div>
  );
}

export function ForumThreadPanel({
  thread,
  isLoading,
  isSendingReply,
  channelId,
  postId,
  currentPubkey,
  profiles,
  typingPubkeys,
  onBack,
  onReply,
  onDeletePost,
  onDeleteReply,
  onTargetReached,
  canDeletePost,
  canModerate = false,
  isDeletingPost,
  targetEventId,
  targetSearchMessageId,
  targetSearchQuery,
}: ForumThreadPanelProps) {
  const scrollRef = React.useRef<HTMLDivElement>(null);
  const { channels } = useChannelNavigation();
  const channelNames = React.useMemo(
    () => channels.filter((c) => c.channelType !== "dm").map((c) => c.name),
    [channels],
  );

  const contentRef = React.useRef<HTMLDivElement>(null);
  const replies = React.useMemo(
    () => sortForumOldestFirst(thread?.replies ?? []),
    [thread?.replies],
  );
  // The post itself is the first row, so a target on the post resolves too.
  const threadRows = React.useMemo(
    () =>
      thread
        ? [
            { id: thread.post.eventId },
            ...replies.map((reply) => ({ id: reply.eventId })),
          ]
        : [],
    [replies, thread],
  );
  const {
    isAtBottom,
    newMessageCount,
    onScroll,
    scrollToBottom,
    scrollToBottomOnNextUpdate,
  } = useAnchoredScroll({
    channelId: postId,
    contentRef,
    highlightTargetMessage: false,
    isLoading: isLoading || !thread,
    messages: threadRows,
    onTargetReached,
    scrollContainerRef: scrollRef,
    targetMessageId: targetEventId,
  });

  // The scroll container and its content wrapper stay mounted while the
  // post loads: the anchored-scroll hook observes them from its first render.
  return (
    <div className={cn("flex h-full flex-col", channelChrome.contentPadding)}>
      <div className="border-b border-border/60 px-4 py-3">
        <Button
          className="gap-1.5 text-muted-foreground"
          onClick={onBack}
          size="sm"
          variant="ghost"
        >
          <ArrowLeft className="h-4 w-4" />
          Back to posts
        </Button>
      </div>

      <div className="relative min-h-0 flex-1">
        <div
          className="h-full overflow-y-auto"
          data-scroll-restoration-id={`forum-thread:${channelId}`}
          data-testid="forum-thread-scroll"
          onCopy={handleTimelineMentionCopy}
          onScroll={onScroll}
          ref={scrollRef}
        >
          <div ref={contentRef}>
            {isLoading || !thread ? (
              <div className="space-y-4 p-4">
                <Skeleton className="h-8 w-3/4" />
                <Skeleton className="h-24 w-full" />
                <Skeleton className="h-16 w-full" />
              </div>
            ) : (
              <ForumThreadContent
                canDeletePost={canDeletePost}
                canModerate={canModerate}
                channelNames={channelNames}
                currentPubkey={currentPubkey}
                isDeletingPost={isDeletingPost}
                onDeletePost={onDeletePost}
                onDeleteReply={onDeleteReply}
                post={thread.post}
                profiles={profiles}
                replies={replies}
                targetSearchMessageId={targetSearchMessageId}
                targetSearchQuery={targetSearchQuery}
              />
            )}
          </div>
        </div>

        {!isAtBottom ? (
          <div className="pointer-events-none absolute inset-x-0 bottom-4 z-10 flex justify-center px-4">
            <UnreadPill
              direction="down"
              label={
                newMessageCount > 0
                  ? unreadCountLabel(newMessageCount)
                  : "Jump to latest"
              }
              onClick={() => scrollToBottom("smooth")}
              testId="forum-thread-scroll-to-latest"
            />
          </div>
        ) : null}
      </div>

      {thread && typingPubkeys && typingPubkeys.length > 0 ? (
        <TypingIndicatorRow
          channel={null}
          className="border-t border-border/60"
          currentPubkey={currentPubkey}
          profiles={profiles}
          typingPubkeys={typingPubkeys}
        />
      ) : null}

      {thread ? (
        <div className="border-t border-border/60 p-4">
          <ForumComposer
            channelId={channelId}
            channelType="forum"
            draftKey={`thread:${postId}`}
            isSending={isSendingReply}
            onSubmit={(content, mentionPubkeys, mediaTags) => {
              // The reply lands at the bottom; follow it there even when the
              // reader had scrolled up to older replies.
              scrollToBottomOnNextUpdate();
              return onReply(content, mentionPubkeys, mediaTags);
            }}
            placeholder="Reply to this post..."
            profiles={profiles}
          />
        </div>
      ) : null}
    </div>
  );
}

function ForumThreadContent({
  canDeletePost,
  canModerate,
  channelNames,
  currentPubkey,
  isDeletingPost,
  onDeletePost,
  onDeleteReply,
  post,
  profiles,
  replies,
  targetSearchMessageId,
  targetSearchQuery,
}: {
  canDeletePost?: boolean;
  canModerate: boolean;
  channelNames: string[];
  currentPubkey?: string;
  isDeletingPost?: boolean;
  onDeletePost?: (eventId: string) => void;
  onDeleteReply?: (eventId: string, options: { asModerator: boolean }) => void;
  post: ForumThreadResponse["post"];
  profiles?: UserProfileLookup;
  /** Replies oldest first; the newest renders at the bottom. */
  replies: ThreadReply[];
  targetSearchMessageId?: string;
  targetSearchQuery?: string;
}) {
  const {
    mentionNames: postMentionNames,
    mentionPubkeysByName: postMentionPubkeysByName,
  } = resolveMentionProps(post.tags, profiles, post.content);
  const postAuthorLabel = resolveUserLabel({
    pubkey: post.pubkey,
    currentPubkey,
    profiles,
    preferResolvedSelfLabel: true,
  });
  const postAvatarUrl =
    profiles?.[post.pubkey.toLowerCase()]?.avatarUrl ?? null;
  const postAuthorIsAgent =
    profiles?.[post.pubkey.toLowerCase()]?.isAgent === true;

  return (
    <>
      <div
        className={cn(
          "group border-b border-border/60 p-4",
          isDeletingPost && "pointer-events-none opacity-50",
        )}
        data-forum-event-id={post.eventId}
        data-message-id={post.eventId}
      >
        <div className="flex items-center gap-2">
          <UserProfilePopover
            pubkey={post.pubkey}
            role={postAuthorIsAgent ? "bot" : undefined}
          >
            <button
              className="flex items-center gap-2 rounded-xl focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-ring"
              type="button"
            >
              <UserAvatar
                accent={postAuthorIsAgent}
                avatarUrl={postAvatarUrl}
                displayName={postAuthorLabel}
                shape={postAuthorIsAgent ? "squircle" : "circle"}
              />
              <span className="text-sm font-semibold text-foreground hover:underline">
                {postAuthorLabel}
              </span>
            </button>
          </UserProfilePopover>
          <span className="text-xs text-muted-foreground">
            {formatRelativeTime(post.createdAt)}
          </span>

          {canDeletePost && onDeletePost ? (
            <DeleteActionMenu
              label="post"
              onConfirm={() => onDeletePost(post.eventId)}
            />
          ) : null}
        </div>
        <div className="mt-3">
          <Markdown
            channelNames={channelNames}
            className="text-sm"
            content={post.content}
            messageId={post.eventId}
            linkPreviewsSuppressed={hasLinkPreviewSuppression(post.tags)}
            linkPreviewTags={post.tags}
            imetaByUrl={parseImetaTags(post.tags)}
            mentionNames={postMentionNames}
            mentionPubkeysByName={postMentionPubkeysByName}
            searchQuery={
              targetSearchMessageId === post.eventId
                ? targetSearchQuery
                : undefined
            }
          />
        </div>
      </div>

      <div className="flex items-center gap-1.5 border-b border-border/60 px-4 py-2.5 text-sm font-medium text-muted-foreground">
        <MessageSquare className="h-4 w-4" />
        {replies.length} {replies.length === 1 ? "reply" : "replies"}
      </div>

      <div className="divide-y divide-border/40">
        {replies.map((reply) => (
          <ReplyRow
            canModerate={canModerate}
            channelNames={channelNames}
            currentPubkey={currentPubkey}
            key={reply.eventId}
            onDelete={onDeleteReply}
            profiles={profiles}
            reply={reply}
            searchQuery={
              targetSearchMessageId === reply.eventId
                ? targetSearchQuery
                : undefined
            }
          />
        ))}

        {replies.length === 0 ? (
          <div className="px-4 py-6 text-center text-sm text-muted-foreground">
            No replies yet. Be the first to respond.
          </div>
        ) : null}
      </div>
    </>
  );
}
