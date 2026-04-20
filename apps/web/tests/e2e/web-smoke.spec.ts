import { expect, test } from "@playwright/test";

test("home route loads with trust framing and map controls", async ({ page }) => {
  await page.goto("/");

  await expect(page.getByRole("link", { name: "RoadSense NS" })).toBeVisible();
  await expect(page.getByText("Community road quality")).toBeVisible();
  await expect(page.getByRole("tablist", { name: "Map mode" })).toBeVisible();
  await expect(page.getByLabel("Road quality legend")).toBeVisible();
});

test("mode switching updates route state", async ({ page }) => {
  await page.goto("/");

  await page.getByRole("button", { name: "Coverage" }).click();
  await expect(page).toHaveURL(/mode=coverage/);
  await expect(page.getByText(/Coverage mode is live/i)).toBeVisible();

  await page.getByRole("button", { name: "Potholes" }).click();
  await expect(page).toHaveURL(/mode=potholes/);
  await expect(page.getByText(/No active potholes are published in this view yet/i)).toBeVisible();
});

test("municipality jump search routes correctly", async ({ page }) => {
  await page.goto("/");

  await page.getByPlaceholder("Halifax, Truro, Kentville…").fill("Halifax");
  await page.getByRole("button", { name: "Go" }).click();

  await expect(page).toHaveURL(/\/municipality\/halifax/);
  await expect(page.locator("#main-content").getByText("Halifax").first()).toBeVisible();
});

test("worst roads report filter round-trips through the URL", async ({ page }) => {
  await page.goto("/reports/worst-roads");

  await expect(page.getByRole("link", { name: "Worst Roads" })).toBeVisible();
  await expect(page.locator("#main-content").getByText("Worst Roads")).toBeVisible();
  await page.getByLabel("Municipality").selectOption("Kentville");
  await page.getByRole("button", { name: "Update report" }).click();

  await expect(page).toHaveURL(/municipality=Kentville/);
});

test("methodology and privacy pages expose trust copy", async ({ page }) => {
  await page.goto("/methodology");
  await expect(page.getByText(/The server, not the phone/i)).toBeVisible();

  await page.goto("/privacy");
  await expect(page.getByText(/does not use ad trackers or session replay tools/i)).toBeVisible();
});
