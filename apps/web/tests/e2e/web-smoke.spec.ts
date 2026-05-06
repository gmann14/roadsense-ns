import { expect, test, type Locator, type Page } from "@playwright/test";

test("home route loads with editorial hero and map controls", async ({ page }) => {
  await page.goto("/");

  await expect(page.getByRole("link", { name: "RoadSense NS" })).toBeVisible();
  await expect(
    page.getByRole("heading", { name: /scored by the people who drive them/i }),
  ).toBeVisible();
  await expect(page.getByRole("tablist", { name: "Map mode" })).toBeVisible();
  await expect(page.getByLabel(/Roughness ramp legend/i)).toBeVisible();
  await expect(page.getByRole("status").filter({ hasText: /Updated|Awaiting/i })).toBeVisible();
});

test("mode switching updates route state", async ({ page }) => {
  await page.goto("/");

  await page.getByRole("button", { name: "Coverage" }).click();
  await expect(page).toHaveURL(/mode=coverage/);
  await expect(page.getByRole("button", { name: "Coverage" })).toHaveAttribute("aria-pressed", "true");

  await page.getByRole("button", { name: "Potholes" }).click();
  await expect(page).toHaveURL(/mode=potholes/);
  await expect(page.getByRole("button", { name: "Potholes" })).toHaveAttribute("aria-pressed", "true");
  await expect(page.getByRole("complementary").getByText(/Pothole map/i)).toBeVisible();
});

test("municipality jump search routes correctly", async ({ page }) => {
  await page.goto("/");

  await page.getByPlaceholder("Halifax, Truro, Lunenburg…").fill("MODL");
  await page.getByRole("button", { name: "Search" }).click();

  await expect(page).toHaveURL(/\/municipality\/municipality-of-the-district-of-lunenburg/);
  await expect(
    page.locator("#main-content").getByText("Municipality of the District of Lunenburg").first(),
  ).toBeVisible();
  await page.waitForTimeout(1_000);
  await expect(page).toHaveURL(/\/municipality\/municipality-of-the-district-of-lunenburg/);
});

test("search exposes a recoverable no-results state", async ({ page }) => {
  await page.goto("/");

  await page.getByPlaceholder("Halifax, Truro, Lunenburg…").fill("zzzzzz");
  await expect(page.getByText(/no municipality or place match/i)).toBeVisible();
  await page.getByRole("button", { name: "Clear" }).click();
  await expect(page.getByPlaceholder("Halifax, Truro, Lunenburg…")).toHaveValue("");
});

test("unfinished report routes redirect back to the map", async ({ page }) => {
  await page.goto("/reports/worst-roads");

  await expect(page).toHaveURL("/");
  await expect(page.getByRole("heading", { name: /scored by the people who drive them/i })).toBeVisible();

  await page.goto("/reports/potholes");
  await expect(page).toHaveURL(/mode=potholes/);
  await expect(page.getByRole("button", { name: "Potholes" })).toHaveAttribute("aria-pressed", "true");
});

test("methodology and privacy pages expose trust copy", async ({ page }) => {
  await page.goto("/methodology");
  await expect(page.getByText(/The server matches clean samples to roads/i)).toBeVisible();

  await page.goto("/privacy");
  await expect(page.getByText(/does not use ad trackers or session replay tools/i)).toBeVisible();
});

test("keyboard users can reach skip link, nav, mode controls, and search", async ({ page }) => {
  await page.goto("/");

  await tabUntilFocused(page, page.getByRole("link", { name: "Skip to content" }));
  await tabUntilFocused(page, page.getByRole("link", { name: "RoadSense NS" }));
  await tabUntilFocused(page, page.getByRole("link", { name: "Map" }));
  await tabUntilFocused(page, page.getByRole("button", { name: "Quality" }));
  await tabUntilFocused(page, page.getByRole("button", { name: "Potholes" }));
  await tabUntilFocused(page, page.getByRole("button", { name: "Coverage" }));
  await tabUntilFocused(page, page.getByPlaceholder("Halifax, Truro, Lunenburg…"));
});

test.describe("mobile", () => {
  test.use({ viewport: { width: 390, height: 844 } });

  test("home route remains usable on a phone-sized viewport", async ({ page }) => {
    await page.goto("/");

    await expect(
      page.getByRole("heading", { name: /scored by the people who drive them/i }),
    ).toBeVisible();
    await expect(page.getByRole("button", { name: "Coverage" })).toBeVisible();
    await expect(page.getByLabel(/Roughness ramp legend/i)).toBeVisible();
  });

  test("unfinished report routes redirect on a phone-sized viewport", async ({ page }) => {
    await page.goto("/reports/worst-roads");

    await expect(page).toHaveURL("/");
    await expect(page.getByRole("button", { name: "Coverage" })).toBeVisible();
  });
});

async function tabUntilFocused(page: Page, locator: Locator, maxTabs = 12) {
  for (let index = 0; index < maxTabs; index += 1) {
    if (await locator.evaluate((element) => element === document.activeElement)) {
      return;
    }

    await page.keyboard.press("Tab");
  }

  await expect(locator).toBeFocused();
}
