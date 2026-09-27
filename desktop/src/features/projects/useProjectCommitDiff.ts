import { useQuery } from "@tanstack/react-query";

import {
  getProjectLocalRepoDiff,
  getProjectRepoDiff,
} from "@/shared/api/projectGit";
import type { ProjectRepoDiff } from "@/shared/api/types";
import type { Repository as Project } from "./hooks";
import { useProjectRepoHost } from "./useProjectRepoHost";

async function fetchProjectCommitDiff(
  project: Project,
  commitHash: string,
  repoSource: "remote" | "local",
  reposDir: string | null | undefined,
  allowRemote: boolean,
): Promise<ProjectRepoDiff> {
  if (repoSource === "local") {
    // Passing only the target commit (no base branch/commit) makes the
    // backend diff the commit against its parent.
    const local = await getProjectLocalRepoDiff({
      reposDir,
      projectDtag: project.dtag,
      cloneUrl: project.cloneUrls[0] ?? null,
      targetCommit: commitHash,
    });
    if (local) return local;
    if (!allowRemote)
      throw new Error(
        "Local checkout is no longer available. Open the repository from Codebase to set up a local copy.",
      );
  }

  const cloneUrl = project.cloneUrls[0];
  if (!cloneUrl) {
    throw new Error("This project has no clone URL to load the commit from.");
  }
  return getProjectRepoDiff({
    cloneUrl,
    defaultBranch: project.defaultBranch,
    targetCommit: commitHash,
  });
}

/**
 * Diff of a single commit against its parent, for the commit detail view.
 * Prefers the local checkout when the repository source is "local" and falls
 * back to a remote fetch only for Buzz-hosted repositories when no checkout exists.
 */
export function useProjectCommitDiffQuery(
  project: Project | null | undefined,
  commitHash: string | null,
  repoSource: "remote" | "local",
  reposDir?: string | null,
) {
  const host = useProjectRepoHost(project);
  return useQuery({
    enabled: Boolean(project && commitHash),
    queryKey: [
      "project",
      project?.id ?? "none",
      "commit-diff",
      repoSource,
      reposDir ?? "default",
      host.kind,
      commitHash ?? "none",
    ],
    queryFn: () => {
      if (!project || !commitHash) {
        return Promise.reject(new Error("No commit selected."));
      }
      return fetchProjectCommitDiff(
        project,
        commitHash,
        repoSource,
        reposDir,
        host.kind === "buzz",
      );
    },
    // A commit's diff is immutable, so never refetch it while cached.
    staleTime: Number.POSITIVE_INFINITY,
    retry: 1,
  });
}
