import { MessageSquareText } from "lucide-react";
import * as React from "react";

import { handleTimelineMentionCopy } from "@/features/messages/lib/timelineMentionCopy";
import { TypingIndicatorRow } from "@/features/messages/ui/TypingIndicatorRow";
import { useAnchoredScroll } from "@/features/messages/ui/useAnchoredScroll";
import type { UserProfileLookup } from "@/features/profile/lib/identity";
import type { Channel, ForumPost } from "@/shared/api/types";
import { channelChrome } from "@/shared/layout/chromeLayout";
import { cn } from "@/shared/lib/cn";
import { Skeleton } from "@/shared/ui/skeleton";
import { UnreadPill, unreadCountLabel } from "@/shared/ui/UnreadPill";

import { ForumComposer } from "./ForumComposer";

type ForumPostListProps = {
  channel: Channel;
  /** Posts oldest first; the newest renders at the bottom. */
  posts: ForumPost[];
  isLoading: boolean;
  currentPubkey?: string;
  profiles?: UserProfileLookup;
  /** Typing pubkeys with no post reference (someone starting a new post). */
  channelTypingPubkeys: string[];
  isComposerOpen: boolean;
  onComposerOpenChange: (open: boolean) => void;
  isCreatingPost: boolean;
  onCreatePost: (
    content: string,
    mentionPubkeys: string[],
    mediaTags?: string[][],
  ) => Promise<unknown>;
  renderPost: (post: ForumPost) => React.ReactNode;
};

/**
 * The forum's post list, laid out like a conversation: oldest post at the
 * top, newest at the bottom above the new-post composer. Scrolling uses the
 * same anchored behavior as channel timelines — it opens at the bottom,
 * follows new posts while the reader is there, and holds the reader's place
 * while they read older posts.
 */
export function ForumPostList({
  channel,
  posts,
  isLoading,
  currentPubkey,
  profiles,
  channelTypingPubkeys,
  isComposerOpen,
  onComposerOpenChange,
  isCreatingPost,
  onCreatePost,
  renderPost,
}: ForumPostListProps) {
  const scrollRef = React.useRef<HTMLDivElement>(null);
  const contentRef = React.useRef<HTMLDivElement>(null);
  const postIds = React.useMemo(
    () => posts.map((post) => ({ id: post.eventId })),
    [posts],
  );
  const {
    isAtBottom,
    newMessageCount,
    onScroll,
    scrollToBottom,
    scrollToBottomOnNextUpdate,
  } = useAnchoredScroll({
    channelId: channel.id,
    contentRef,
    isLoading,
    messages: postIds,
    scrollContainerRef: scrollRef,
  });

  return (
    <div className={cn("flex h-full flex-col", channelChrome.contentPadding)}>
      <div className="relative min-h-0 flex-1">
        <div
          className="h-full overflow-y-auto"
          data-scroll-restoration-id={`forum-list:${channel.id}`}
          data-testid="forum-post-list"
          onCopy={handleTimelineMentionCopy}
          onScroll={onScroll}
          ref={scrollRef}
        >
          <div ref={contentRef}>
            {isLoading ? (
              <div className="space-y-3 p-4">
                <Skeleton className="h-24 w-full rounded-xl" />
                <Skeleton className="h-24 w-full rounded-xl" />
                <Skeleton className="h-24 w-full rounded-xl" />
              </div>
            ) : posts.length === 0 ? (
              <div className="flex flex-col items-center justify-center gap-3 px-4 py-16 text-center">
                <MessageSquareText className="h-10 w-10 text-muted-foreground/40" />
                <div>
                  <p className="text-sm font-medium text-foreground/70">
                    No posts yet
                  </p>
                  <p className="mt-1 text-xs text-muted-foreground">
                    Start a discussion by creating the first post.
                  </p>
                </div>
              </div>
            ) : (
              <div className="p-4">
                {posts.map((post) => (
                  <div
                    className="content-visibility-auto-interactive pb-3"
                    data-message-id={post.eventId}
                    key={post.eventId}
                  >
                    {renderPost(post)}
                  </div>
                ))}
              </div>
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
              testId="forum-scroll-to-latest"
            />
          </div>
        ) : null}
      </div>

      {channelTypingPubkeys.length > 0 ? (
        <TypingIndicatorRow
          channel={channel}
          className="border-t border-border/60"
          currentPubkey={currentPubkey}
          profiles={profiles}
          typingPubkeys={channelTypingPubkeys}
        />
      ) : null}

      <div className="border-t border-border/60 p-4">
        {isComposerOpen ? (
          <ForumComposer
            channelId={channel.id}
            channelType="forum"
            draftKey={`forum:${channel.id}`}
            isSending={isCreatingPost}
            onCancel={() => onComposerOpenChange(false)}
            onSubmit={async (content, mentionPubkeys, mediaTags) => {
              // The new post lands at the bottom; follow it there even when
              // the reader had scrolled up to older posts.
              scrollToBottomOnNextUpdate();
              await onCreatePost(content, mentionPubkeys, mediaTags);
              onComposerOpenChange(false);
            }}
            placeholder="Write your post..."
            profiles={profiles}
          />
        ) : (
          <button
            className="w-full rounded-xl border border-dashed border-border/80 px-4 py-3 text-left text-sm text-muted-foreground transition-colors hover:border-border hover:bg-accent/30 hover:text-foreground"
            disabled={!channel.isMember || channel.archivedAt !== null}
            onClick={() => onComposerOpenChange(true)}
            type="button"
          >
            {channel.archivedAt
              ? "This forum is archived."
              : !channel.isMember
                ? "Join this forum to create posts."
                : "Start a new post..."}
          </button>
        )}
      </div>
    </div>
  );
}
