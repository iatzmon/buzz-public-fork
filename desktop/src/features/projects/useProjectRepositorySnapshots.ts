import { useQueries } from "@tanstack/react-query";

import { useCommunities } from "@/features/communities/useCommunities";
import type {
  ProjectRepoSnapshot,
  Repository,
} from "@/features/projects/hooks";
import { fetchRepoState } from "@/features/projects/hooks";
import { resolveProjectDefaultBranch } from "@/features/projects/lib/projectBranches";
import { projectRepoHostForRepository } from "@/features/projects/lib/projectRepoHost";
import {
  getProjectLocalRepoSnapshot,
  getProjectRepoSnapshot,
} from "@/shared/api/projectGit";
import { useRelayOrigin } from "@/shared/lib/useRelayOrigin";

export type ProjectRepositorySnapshotResult = {
  branch: string | null;
  error: unknown;
  isLoading: boolean;
  localPath: string | null;
  repository: Repository;
  snapshot: ProjectRepoSnapshot | null;
  source: "local" | "remote";
};

/** Reads external repositories from local checkouts and Buzz repositories from the relay. */
export function useProjectRepositorySnapshots(
  repositories: Repository[],
  enabled = true,
): ProjectRepositorySnapshotResult[] {
  const { activeCommunity } = useCommunities();
  const reposDir = activeCommunity?.reposDir;
  const relayOrigin = useRelayOrigin();
  const sources = repositories.map((repository) =>
    projectRepoHostForRepository(repository, relayOrigin).kind === "external"
      ? ("local" as const)
      : ("remote" as const),
  );
  const queries = useQueries({
    queries: repositories.map((repository, index) => ({
      enabled: Boolean(enabled && relayOrigin && repository.cloneUrls[0]),
      queryFn: async () => {
        if (sources[index] === "local") {
          const local = await getProjectLocalRepoSnapshot({
            reposDir,
            projectDtag: repository.dtag,
            cloneUrl: repository.cloneUrls[0],
          });
          return {
            branch: null,
            snapshot: local?.snapshot ?? null,
            localPath: local?.path ?? null,
          };
        }
        const repoState = await fetchRepoState(repository);
        const defaultBranch = resolveProjectDefaultBranch(
          repository.defaultBranch,
          repoState,
        );
        const snapshot = await getProjectRepoSnapshot({
          baseBranch: defaultBranch,
          cloneUrl: repository.cloneUrls[0],
          defaultBranch,
        });
        return { snapshot, localPath: null, branch: defaultBranch };
      },
      queryKey: [
        "project",
        repository.id,
        "sidebar-snapshot",
        relayOrigin,
        sources[index],
        reposDir ?? "default",
        repository.cloneUrls[0],
        repository.defaultBranch,
      ],
      retry: 1,
      staleTime: sources[index] === "local" ? 10_000 : 30_000,
    })),
  });

  return repositories.map((repository, index) => {
    const query = queries[index];
    return {
      branch: query?.data?.branch ?? null,
      error:
        enabled && !repository.cloneUrls[0]
          ? new Error("Repository has no clone URL.")
          : query?.error,
      isLoading: Boolean(enabled && (!relayOrigin || query?.isLoading)),
      localPath: query?.data?.localPath ?? null,
      repository,
      snapshot: query?.data?.snapshot ?? null,
      source: sources[index],
    };
  });
}
