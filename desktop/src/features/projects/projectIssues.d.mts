import type { RelayEvent } from "@/shared/api/types";

export type ProjectIssueStatus =
  | "Triage"
  | "Backlog"
  | "In Progress"
  | "In Review"
  | "Done"
  | "Closed";

export type ProjectTaskCategory = "issue" | "change-request" | "improvement";

export type ProjectIssueComment = {
  id: string;
  content: string;
  tags: string[][];
  author: string;
  createdAt: number;
};

export type ProjectIssue = {
  id: string;
  title: string;
  content: string;
  tags: string[][];
  author: string;
  createdAt: number;
  repoAddress: string | null;
  channelId: string | null;
  originAgentName: string | null;
  labels: string[];
  category: ProjectTaskCategory;
  recipients: string[];
  assignees: string[];
  assigneeOperationHeads: Record<string, string>;
  status: ProjectIssueStatus;
  statusEventId: string | null;
  updatedAt: number;
  comments: ProjectIssueComment[];
};

export const ISSUE_ASSIGNMENT_LABEL: "assignment";
export const ISSUE_UNASSIGNMENT_LABEL: "unassignment";

export const PROJECT_ISSUE_STATUS: {
  TRIAGE: "Triage";
  BACKLOG: "Backlog";
  IN_PROGRESS: "In Progress";
  IN_REVIEW: "In Review";
  DONE: "Done";
  CLOSED: "Closed";
};

export function getTag(event: RelayEvent, name: string): string | undefined;
export function getAllTags(event: RelayEvent, name: string): string[];
export function getImetaTags(event: RelayEvent): string[][];
/**
 * Reduce an issue root and its related events into a {@link ProjectIssue}.
 * `communityOwners` (lowercase hex pubkeys with the relay `owner` role) are
 * trusted like the issue author and repo owner for status and assignment.
 */
export function eventToProjectIssue(
  issue: RelayEvent,
  statusEvents?: RelayEvent[],
  commentEvents?: RelayEvent[],
  communityOwners?: Iterable<string>,
): ProjectIssue;
/** Reduce issue roots into issues, newest activity first. */
export function projectIssueEventsToIssues(
  issueEvents: RelayEvent[],
  statusEvents?: RelayEvent[],
  commentEvents?: RelayEvent[],
  communityOwners?: Iterable<string>,
): ProjectIssue[];
export function nextProjectIssueCommentCreatedAt(
  issue: ProjectIssue,
  now: number,
  author: string,
): number;
export function buildGitIssueTags(input: {
  repoAddress: string;
  repoOwner: string;
  title: string;
  labels?: string[];
}): string[][];
export function buildGitStatusTags(input: {
  issueId: string;
  repoAddress?: string | null;
  repoOwner?: string | null;
}): string[][];
