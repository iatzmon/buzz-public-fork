import { useIsManagedAgent } from "@/features/agent-memory/hooks";
import { useCommunityOwnerPubkeys } from "@/features/community-members/hooks";
import type {
  ProjectIssue,
  ProjectPullRequest,
  Repository,
} from "@/features/projects/hooks";
import type { UserProfileLookup } from "@/features/profile/lib/identity";
import { useIdentityQuery } from "@/shared/api/hooks";
import { normalizePubkey } from "@/shared/lib/pubkey";
import { IssueAssigneesRow } from "./IssueAssigneesRow";
import { PullRequestReviewersRow } from "./PullRequestReviewersRow";

export function ProjectWorkItemContextActions({
  issue,
  profiles,
  pullRequest,
  repository,
}: {
  issue?: ProjectIssue | null;
  profiles?: UserProfileLookup;
  pullRequest?: ProjectPullRequest | null;
  repository: Repository;
}) {
  const identityQuery = useIdentityQuery();
  const viewerPubkey = identityQuery.data?.pubkey;
  const viewer = viewerPubkey ? normalizePubkey(viewerPubkey) : null;
  const isOwner = viewer === normalizePubkey(repository.owner);
  const isManagedAgentOwner = useIsManagedAgent(repository.owner) === true;
  const communityOwners = useCommunityOwnerPubkeys();

  if (issue) {
    if (!viewer) return null;
    const isAuthor = viewer === normalizePubkey(issue.author);
    // Community owners are issue authorities (not PR authorities) and sign
    // as themselves rather than as a managed agent.
    const isCommunityOwner = communityOwners.includes(viewer);
    const canAssignOthers =
      isAuthor || isOwner || isCommunityOwner || isManagedAgentOwner;
    return (
      <div data-testid="project-context-task-assignment">
        <IssueAssigneesRow
          canAssignOthers={canAssignOthers}
          contextActions
          issue={issue}
          profiles={profiles}
          project={repository}
          signAsManagedOwner={
            isManagedAgentOwner && !isOwner && !isCommunityOwner
          }
          showAssignees={false}
          showSelfAssignmentState
          testIdPrefix="project-context-issue"
          viewerPubkey={viewer}
        />
      </div>
    );
  }

  if (pullRequest) {
    const isAuthor = viewer === normalizePubkey(pullRequest.author);
    const canRequestReview =
      viewer !== null &&
      (pullRequest.status === "Open" || pullRequest.status === "Draft") &&
      (isAuthor || isOwner || isManagedAgentOwner);
    if (!canRequestReview) return null;
    return (
      <div data-testid="project-context-reviewers">
        <PullRequestReviewersRow
          actionLabel="Add Reviewer"
          canRequest={canRequestReview}
          contextActions
          profiles={profiles}
          project={repository}
          pullRequest={pullRequest}
          signAsManagedOwner={isManagedAgentOwner && !isOwner}
          showDecisionActors={false}
          showSummary={false}
          summaryTestId="project-context-review-summary"
        />
      </div>
    );
  }

  return null;
}
