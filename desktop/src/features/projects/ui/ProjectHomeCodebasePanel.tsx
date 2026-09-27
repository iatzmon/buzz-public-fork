import { ChevronDown, FolderGit2 } from "lucide-react";

import type { Project, Repository } from "@/features/projects/hooks";
import { useCommunities } from "@/features/communities/useCommunities";
import { useProjectRepositorySnapshots } from "@/features/projects/useProjectRepositorySnapshots";
import { Button } from "@/shared/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/shared/ui/dropdown-menu";
import { ProjectRepositoryManagement } from "./ProjectRepositoryManagement";
import { RepositoryFilesPanel } from "./ProjectRepositoryPanel";
import { useRepositoryFileContentSource } from "./useRepositoryFileContentSource";

export function ProjectHomeCodebasePanel({
  identityPubkey,
  onFilesContextChange,
  onOpenCommit,
  onRepositoryAdded,
  onSelectRepository,
  project,
  projects,
  repository,
}: {
  identityPubkey?: string;
  onFilesContextChange?: (context: {
    kind: "file" | "folder";
    onBack?: () => void;
    path: string;
  }) => void;
  onOpenCommit?: (commitHash: string) => void;
  onRepositoryAdded: (repositoryId: string) => void;
  onSelectRepository: (repositoryId: string) => void;
  project: Project;
  projects: Project[];
  repository: Repository | null;
}) {
  const { activeCommunity } = useCommunities();
  const [result] = useProjectRepositorySnapshots(
    repository ? [repository] : [],
  );
  const fileContentSource = useRepositoryFileContentSource({
    activeBranch: result?.branch ?? null,
    activeTag: null,
    pullRequest: null,
    repository,
    selectedTag: null,
    reposDir: activeCommunity?.reposDir,
    source: result?.source ?? "remote",
  });
  const snapshot = result?.snapshot ?? null;
  const files = snapshot?.files ?? [];

  if (!repository) {
    return (
      <div
        className="space-y-3 px-4 pb-6 pt-1"
        data-testid="project-home-codebase-empty"
      >
        <p className="text-sm text-muted-foreground">
          Attach a repository to browse the file tree beside this channel.
        </p>
        <ProjectRepositoryManagement
          identityPubkey={identityPubkey}
          onChange={onRepositoryAdded}
          project={project}
          projects={projects}
        />
      </div>
    );
  }

  return (
    <div
      className="flex min-h-0 flex-1 flex-col overflow-hidden"
      data-testid="project-home-codebase-panel"
    >
      {project.repositories.length > 1 ? (
        <div className="shrink-0 px-4 pb-2">
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <Button
                className="h-7 max-w-full justify-start gap-2 px-2 text-sm font-normal"
                data-testid="project-home-codebase-repo-trigger"
                size="sm"
                type="button"
                variant="ghost"
              >
                <FolderGit2 className="h-4 w-4 shrink-0 text-muted-foreground" />
                <span className="min-w-0 truncate">{repository.name}</span>
                <ChevronDown className="ml-auto h-3.5 w-3.5 shrink-0 text-muted-foreground" />
              </Button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="start">
              {project.repositories.map((candidate) => (
                <DropdownMenuItem
                  key={candidate.id}
                  onSelect={() => onSelectRepository(candidate.id)}
                >
                  {candidate.name}
                </DropdownMenuItem>
              ))}
            </DropdownMenuContent>
          </DropdownMenu>
        </div>
      ) : null}
      {result?.source === "local" ? (
        <p
          className="px-4 pb-2 text-sm text-muted-foreground"
          data-testid="project-home-local-source"
        >
          {result.localPath
            ? `Local working copy · ${result.localPath}. Includes uncommitted changes.`
            : result.error
              ? "Could not read the local checkout. Open the repository from Codebase to check it."
              : result.isLoading
                ? "Looking for a local checkout…"
                : "No local checkout found. Open this repository from Codebase to set up a local copy."}
        </p>
      ) : null}
      <div className="min-h-0 flex-1 overflow-y-auto px-4 pb-4">
        <RepositoryFilesPanel
          key={`${repository.id}:${result?.source}:${activeCommunity?.reposDir}`}
          error={result?.error}
          fallbackAuthorPubkey={repository.owner}
          fileContentSource={fileContentSource}
          files={files}
          isLoading={result?.isLoading}
          onContextChange={onFilesContextChange}
          onOpenCommit={onOpenCommit}
          snapshot={snapshot}
        />
      </div>
    </div>
  );
}
