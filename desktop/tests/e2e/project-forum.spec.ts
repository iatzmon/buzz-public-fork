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
