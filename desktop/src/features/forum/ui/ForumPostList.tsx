import { MessageSquareText } from "lucide-react";
import * as React from "react";

import { handleTimelineMentionCopy } from "@/features/messages/lib/timelineMentionCopy";
import { TypingIndicatorRow } from "@/features/messages/ui/TypingIndicatorRow";
import type { UserProfileLookup } from "@/features/profile/lib/identity";
import type { Channel, ForumPost } from "@/shared/api/types";
import { channelChrome } from "@/shared/layout/chromeLayout";
import { cn } from "@/shared/lib/cn";
import { Skeleton } from "@/shared/ui/skeleton";

import { ForumComposer } from "./ForumComposer";

type ForumPostListProps = {
  channel: Channel;
  /** Posts by latest activity, newest first; the newest renders at the top. */
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
 * The forum's post list: the new-post composer on top, then the posts with
 * the most recent activity first. The list opens at the top.
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

  return (
    <div className={cn("flex h-full flex-col", channelChrome.contentPadding)}>
      <div className="border-b border-border/60 p-4">
        {isComposerOpen ? (
          <ForumComposer
            autocompleteBelow
            channelId={channel.id}
            channelType="forum"
            draftKey={`forum:${channel.id}`}
            isSending={isCreatingPost}
            onCancel={() => onComposerOpenChange(false)}
            onSubmit={async (content, mentionPubkeys, mediaTags) => {
              await onCreatePost(content, mentionPubkeys, mediaTags);
              onComposerOpenChange(false);
              // The new post lands at the top; show it there even when the
              // reader had scrolled down to older posts.
              scrollRef.current?.scrollTo({ top: 0 });
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

      {channelTypingPubkeys.length > 0 ? (
        <TypingIndicatorRow
          channel={channel}
          className="border-b border-border/60"
          currentPubkey={currentPubkey}
          profiles={profiles}
          typingPubkeys={channelTypingPubkeys}
        />
      ) : null}

      <div
        className="min-h-0 flex-1 overflow-y-auto"
        data-scroll-restoration-id={`forum-list:${channel.id}`}
        data-testid="forum-post-list"
        onCopy={handleTimelineMentionCopy}
        ref={scrollRef}
      >
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
  );
}
