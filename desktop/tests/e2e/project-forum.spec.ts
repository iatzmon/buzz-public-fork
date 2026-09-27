import { expect, test } from "@playwright/test";

import { installMockBridge } from "../helpers/bridge";
import { waitForAnimations } from "../helpers/animations";

const CHANNEL = "a27e1ee9-76a6-5bdf-a5d5-1d85610dad11";
const POST = "mock-forum-release-thread";
const REPLY = "mock-forum-release-reply";
const OWNER = "deadbeef".repeat(8);
const PROJECT = `30621:${OWNER}:buzz`;

test.beforeEach(async ({ page }) => {
  await page.addInitScript(() => {
    window.localStorage.setItem(
      "buzz-feature-overrides-v1",
      JSON.stringify({ projects: true }),
    );
  });
  await installMockBridge(page, { projectAccessChannelId: CHANNEL });
});

test("a project forum opens posts, sends replies and returns to its list", async ({
  page,
}) => {
  await page.goto(`/#/channels/${CHANNEL}`);
  await expect(page.getByTestId("project-home-context-panel")).toBeVisible();
  await page.getByTestId(`forum-post-card-${POST}`).click();
  await expect(page).toHaveURL(new RegExp(`/posts/${POST}$`));
  await expect(page.getByTestId("forum-thread-scroll")).toBeVisible();
  await expect(page.getByTestId("project-home-context-panel")).toBeVisible();

  const forum = page.getByRole("region", { name: "Forum posts" });
  const editor = forum.locator(".rich-text-composer [contenteditable='true']");
  await editor.fill("Reply from a project forum.");
  await forum.getByTestId("send-message").click();
  await expect(page.getByTestId("forum-thread-scroll")).toContainText(
    "Reply from a project forum.",
  );
  await waitForAnimations(page);
  await page.screenshot({ path: "test-results/project-forum/thread.png" });

  await page.getByRole("button", { name: "Back to posts" }).click();
  await expect(page).toHaveURL(new RegExp(`/channels/${CHANNEL}$`));
  await expect(page.getByTestId(`forum-post-card-${POST}`)).toBeVisible();
  await expect(page.getByTestId("project-home-context-panel")).toBeVisible();
  await page.goForward();
  await expect(page.getByTestId("forum-thread-scroll")).toBeVisible();
});

test("a cold reply deep link retains the project and scrolls to its target", async ({
  page,
}) => {
  await page.goto(`/#/channels/${CHANNEL}/posts/${POST}?replyId=${REPLY}`);
  const target = page.locator(`[data-forum-event-id="${REPLY}"]`);
  await expect(page.getByTestId("project-home-context-panel")).toBeVisible();
  await expect(target).toBeVisible();
  await expect
    .poll(() =>
      target.evaluate((element) => {
        const rect = element.getBoundingClientRect();
        return rect.top >= 0 && rect.bottom <= window.innerHeight;
      }),
    )
    .toBe(true);
  await expect
    .poll(() =>
      page
        .getByTestId("forum-thread-scroll")
        .evaluate(
          (element) =>
            element.scrollHeight - element.clientHeight - element.scrollTop,
        ),
    )
    .toBeGreaterThan(2);
});

test("opening the project directly keeps its forum posts interactive", async ({
  page,
}) => {
  await page.goto(`/#/projects/${encodeURIComponent(PROJECT)}`);
  await expect(page.getByTestId("project-home-context-panel")).toBeVisible();
  await page.getByTestId(`forum-post-card-${POST}`).click();
  await expect(page).toHaveURL(
    new RegExp(`/channels/${CHANNEL}/posts/${POST}$`),
  );
  await expect(page.getByTestId("forum-thread-scroll")).toBeVisible();
  await page.getByRole("button", { name: "Back to posts" }).click();
  await expect(page.getByTestId(`forum-post-card-${POST}`)).toBeVisible();
  await expect(page.getByTestId("project-home-context-panel")).toBeVisible();
});

test("project sidebar links open their panel beside the forum", async ({
  page,
}) => {
  await page.goto(`/#/channels/${CHANNEL}`);
  await expect(page.getByTestId("project-home-context-panel")).toBeVisible();
  await page.getByTestId("project-home-context-tasks").click();
  const sheet = page.getByTestId("project-home-workspace-sheet");
  await expect(sheet).toBeVisible();
  await expect(sheet).toHaveAttribute("data-tab", "issues");
  await expect(page.getByTestId(`forum-post-card-${POST}`)).toBeVisible();

  await page.getByTestId(`forum-post-card-${POST}`).click();
  await expect(page.getByTestId("forum-thread-scroll")).toBeVisible();
  await page.getByTestId("project-home-context-tasks").click();
  await expect(sheet).toBeVisible();

  await page.getByTestId("project-home-drawer-toggle").click();
  await expect(sheet).toHaveCount(0);
  await expect(page.getByTestId("project-home-context-panel")).toBeVisible();
  await page.getByTestId("project-home-context-files").click();
  await expect(sheet).toHaveAttribute("data-tab", "files");
});

for (const [control, tab, title] of [
  ["tasks", "issues", "Tasks"],
  ["reviews", "prs", "Reviews"],
  ["commits", "commits", "Commits"],
  ["files", "files", "Files"],
  ["people", "contributors", "People"],
]) {
  test(`project forum ${title} panel opens and closes from a thread`, async ({
    page,
  }) => {
    await page.goto(`/#/channels/${CHANNEL}/posts/${POST}`);
    await page.getByTestId(`project-home-context-${control}`).click();
    const panel = page.getByTestId("idle-auxiliary-panel");
    await expect(panel).toBeVisible();
    await expect(
      panel.getByTestId("project-home-workspace-sheet"),
    ).toHaveAttribute("data-tab", tab);
    await expect(panel.getByText(title, { exact: true }).first()).toBeVisible();
    await expect(page.getByTestId("forum-thread-scroll")).toBeVisible();
    if (control === "tasks") {
      await waitForAnimations(page);
      await page.screenshot({ path: "test-results/project-forum/tasks.png" });
    }
    await panel
      .getByRole("button", { name: "Close panel", exact: true })
      .click();
    await expect(panel).toHaveCount(0);
    await expect(page.getByTestId("project-home-context-panel")).toBeVisible();
    await expect(page.getByTestId("forum-thread-scroll")).toBeVisible();
  });
}

test("project forum codebase link opens its repository", async ({ page }) => {
  await page.goto(`/#/channels/${CHANNEL}`);
  await page.getByTestId("project-home-context-repo-buzz").click();
  await expect(page).toHaveURL(/repositoryId=/);
  await expect(page.getByTestId("project-home-context-panel")).toHaveCount(0);
  await expect(page.getByTestId("project-detail-scroll")).toBeVisible();
});

test("forum Files switches between Buzz remote and GitHub local content", async ({
  page,
}) => {
  await page.addInitScript(() => {
    window.__BUZZ_E2E_PROJECT_LOCAL_REPO_SNAPSHOT__ = {
      path: "/tmp/buzz/REPOS/relay-tools",
      snapshot: {
        latest_commit: null,
        commits: [],
        contributors: [],
        files: [
          {
            path: "local-only.txt",
            kind: "blob",
            size: 18,
            preview_content: null,
            last_changed_at: null,
            latest_commit: null,
          },
        ],
      },
    };
    window.__BUZZ_E2E_PROJECT_REPO_FILE_CONTENTS__ = {
      "local-only.txt": "Local checkout content",
    };
  });
  await page.goto(`/#/channels/${CHANNEL}/posts/${POST}`);
  await page.getByTestId("project-home-context-files").click();
  const panel = page.getByTestId("project-home-codebase-panel");
  await panel.getByTestId("project-home-codebase-repo-trigger").click();
  await page.getByRole("menuitem", { name: "buzz", exact: true }).click();
  await expect(
    panel.getByRole("row", { name: "Open directory crates" }),
  ).toBeVisible();
  await panel.getByTestId("project-home-codebase-repo-trigger").click();
  await page
    .getByRole("menuitem", { name: "relay-tools", exact: true })
    .click();
  await expect(panel.getByTestId("project-home-local-source")).toContainText(
    "Local working copy",
  );
  await expect(
    panel.getByRole("row", { name: "Open directory crates" }),
  ).toHaveCount(0);
  await panel.getByRole("row", { name: "Open file local-only.txt" }).click();
  await expect(
    panel.getByText("Local checkout content", { exact: true }),
  ).toBeVisible();
  await expect(page.getByTestId("forum-thread-scroll")).toBeVisible();
  const calls = await page.evaluate(
    () => window.__BUZZ_E2E_COMMAND_PAYLOADS__ ?? [],
  );
  expect(
    calls.some(
      ({ command }) => command === "get_project_local_repo_file_content",
    ),
  ).toBe(true);
  expect(
    calls.filter(
      ({ command, payload }) =>
        command === "get_project_repo_snapshot" &&
        String((payload as { cloneUrl?: string }).cloneUrl).includes(
          "github.com",
        ),
    ),
  ).toEqual([]);
  await waitForAnimations(page);
  await panel.screenshot({
    path: "test-results/project-forum/local-files.png",
  });
  await panel.getByTestId("project-home-codebase-repo-trigger").click();
  await page.getByRole("menuitem", { name: "buzz", exact: true }).click();
  await expect(
    panel.getByRole("row", { name: "Open directory crates" }),
  ).toBeVisible();
  await expect(
    panel.getByText("Local checkout content", { exact: true }),
  ).toHaveCount(0);
});

test("forum Files explains a missing external checkout without trying GitHub auth", async ({
  page,
}) => {
  await page.goto(`/#/channels/${CHANNEL}`);
  await page.getByTestId("project-home-context-files").click();
  await page.getByTestId("project-home-codebase-repo-trigger").click();
  await page
    .getByRole("menuitem", { name: "relay-tools", exact: true })
    .click();
  await expect(page.getByTestId("project-home-local-source")).toContainText(
    "No local checkout found",
  );
  await expect(
    page.getByText("Could not load the repository file tree."),
  ).toHaveCount(0);
  await expect(page.getByText("No files have been pushed yet.")).toHaveCount(0);
  const calls = await page.evaluate(
    () => window.__BUZZ_E2E_COMMAND_PAYLOADS__ ?? [],
  );
  expect(
    calls.filter(
      ({ command, payload }) =>
        command === "get_project_repo_snapshot" &&
        String((payload as { cloneUrl?: string }).cloneUrl).includes(
          "github.com",
        ),
    ),
  ).toEqual([]);
});

test("forum commits read the selected external repository locally", async ({
  page,
}) => {
  await page.addInitScript(() => {
    const commit = {
      hash: "a".repeat(40),
      short_hash: "aaaaaaa",
      author_name: "Alice",
      author_email: "alice@example.com",
      timestamp: 2000000000,
      subject: "Local-only commit",
    };
    window.__BUZZ_E2E_PROJECT_LOCAL_REPO_SNAPSHOT__ = {
      path: "/tmp/buzz/REPOS/relay-tools",
      snapshot: {
        latest_commit: commit,
        commits: [commit],
        contributors: [],
        files: [],
      },
    };
  });
  await page.goto(`/#/channels/${CHANNEL}`);
  await expect(page.getByTestId("project-home-context-commits")).toBeVisible();
  await page.evaluate(() => {
    const w = window as typeof window & {
      __TAURI_INTERNALS__: {
        invoke: (
          command: string,
          payload: unknown,
          options: unknown,
        ) => Promise<unknown>;
      };
    };
    const original = w.__TAURI_INTERNALS__.invoke.bind(w.__TAURI_INTERNALS__);
    w.__TAURI_INTERNALS__.invoke = async (command, payload, options) => {
      if (command === "get_project_local_repo_diff") {
        window.__BUZZ_E2E_COMMAND_PAYLOADS__?.push({ command, payload });
        return {
          files: [],
          additions: 0,
          deletions: 0,
          commit_body: "Local commit diff loaded",
        };
      }
      return original(command, payload, options);
    };
  });
  await page.getByTestId("project-home-context-commits").click();
  const sheet = page.getByTestId("project-home-workspace-sheet");
  await sheet.getByRole("button", { name: "aaaaaaa", exact: true }).click();
  await expect(
    sheet.getByText("Local commit diff loaded", { exact: true }),
  ).toBeVisible();
  const calls = await page.evaluate(
    () => window.__BUZZ_E2E_COMMAND_PAYLOADS__ ?? [],
  );
  const local = calls.find(
    ({ command }) => command === "get_project_local_repo_diff",
  );
  expect(local?.payload).toMatchObject({
    projectDtag: "relay-tools",
    targetCommit: "a".repeat(40),
  });
  expect(
    calls.filter(
      ({ command, payload }) =>
        ["get_project_repo_snapshot", "get_project_repo_diff"].includes(
          command,
        ) &&
        String((payload as { cloneUrl?: string }).cloneUrl).includes(
          "github.com",
        ),
    ),
  ).toEqual([]);
});
