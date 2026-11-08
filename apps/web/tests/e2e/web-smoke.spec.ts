import { expect, test, type Locator, type Page } from "@playwright/test";

test("home route loads with map controls", async ({ page }) => {
  await page.goto("/");

  await expect(page.getByRole("link", { name: "RoadSense NS" })).toBeVisible();
  await expect(page.getByRole("tablist", { name: "Map mode" })).toBeVisible();
  await expect(page.getByLabel(/Roughness ramp legend/i)).toBeVisible();
  // The freshness pill only renders when /stats returns data_updated_at, so
  // it isn't asserted here (the smoke run may have no API behind it).
});

test("mode switching updates route state", async ({ page }) => {
  await page.goto("/");

  await page.getByRole("tab", { name: "Coverage", exact: true }).click();
  await expect(page).toHaveURL(/mode=coverage/);
  await expect(page.getByRole("tab", { name: "Coverage", exact: true })).toHaveAttribute("aria-selected", "true");

  await page.getByRole("tab", { name: "Potholes", exact: true }).click();
  await expect(page).toHaveURL(/mode=potholes/);
  await expect(page.getByRole("tab", { name: "Potholes", exact: true })).toHaveAttribute("aria-selected", "true");
  await expect(page.getByRole("complementary").getByText(/Pothole map/i)).toBeVisible();
});

test("municipality jump search routes correctly", async ({ page }) => {
  await page.goto("/");

  await page.getByPlaceholder("Halifax, Truro, Lunenburg…").fill("MODL");
  await page.getByRole("button", { name: "Search", exact: true }).click();

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
  await expect(page.getByRole("tablist", { name: "Map mode" })).toBeVisible();

  await page.goto("/reports/potholes");
  await expect(page).toHaveURL(/mode=potholes/);
  await expect(page.getByRole("tab", { name: "Potholes", exact: true })).toHaveAttribute("aria-selected", "true");
});

test("methodology and privacy pages expose trust copy", async ({ page }) => {
  await page.goto("/methodology");
  await expect(page.getByText(/The server matches clean samples to roads/i)).toBeVisible();

  await page.goto("/privacy");
  await expect(page.getByText(/doesn.t use cookies, analytics or ad trackers/i)).toBeVisible();
});

test("store listing pages load without the API", async ({ page }) => {
  for (const [path, heading] of [
    ["/privacy", "Public map, private contributors"],
    ["/support", "RoadSense NS help"],
    ["/terms", "Terms of use"],
  ] as const) {
    const response = await page.goto(path);
    expect(response?.status()).toBe(200);
    await expect(page.getByRole("heading", { level: 1, name: heading })).toBeVisible();
    await expect(page.getByRole("contentinfo").getByRole("link", { name: "Terms" })).toBeVisible();
  }
});

test("keyboard users can reach skip link, nav, mode controls, and search", async ({ page }) => {
  await page.goto("/");

  await tabUntilFocused(page, page.getByRole("link", { name: "Skip to content" }));
  await tabUntilFocused(page, page.getByRole("link", { name: "RoadSense NS" }));
  await tabUntilFocused(page, page.getByRole("link", { name: "Map", exact: true }));
  await tabUntilFocused(page, page.getByRole("tab", { name: "Quality" }));
  await tabUntilFocused(page, page.getByRole("tab", { name: "Potholes" }));
  await tabUntilFocused(page, page.getByRole("tab", { name: "Coverage" }));
  await tabUntilFocused(page, page.getByPlaceholder("Halifax, Truro, Lunenburg…"));
});

test.describe("mobile", () => {
  test.use({ viewport: { width: 390, height: 844 } });

  test("home route remains usable on a phone-sized viewport", async ({ page }) => {
    await page.goto("/");

    await expect(page.getByRole("tab", { name: "Coverage", exact: true })).toBeVisible();
    await expect(page.getByLabel(/Roughness ramp legend/i)).toBeVisible();
  });

  test("search opens from a compact toggle on a phone", async ({ page }) => {
    await page.goto("/");

    const search = page.getByPlaceholder("Halifax, Truro, Lunenburg…");
    await expect(search).toBeHidden();
    await page.getByRole("button", { name: "Search the map" }).click();
    await expect(search).toBeVisible();
    await search.fill("Truro");
    await page.getByRole("button", { name: "Search", exact: true }).click();
    await expect(page).toHaveURL(/\/municipality\/truro/);
  });

  test("the mode switcher stays usable while the pothole drawer is open", async ({ page }) => {
    await page.goto("/?mode=potholes");

    await expect(page.getByRole("complementary")).toBeVisible();
    await page.getByRole("tab", { name: "Coverage", exact: true }).click();
    await expect(page).toHaveURL(/mode=coverage/);
  });

  test("unfinished report routes redirect on a phone-sized viewport", async ({ page }) => {
    await page.goto("/reports/worst-roads");

    await expect(page).toHaveURL("/");
    await expect(page.getByRole("tab", { name: "Coverage", exact: true })).toBeVisible();
  });
});

async function tabUntilFocused(page: Page, locator: Locator, maxTabs = 30) {
  for (let index = 0; index < maxTabs; index += 1) {
    if (await locator.evaluate((element) => element === document.activeElement)) {
      return;
    }

    await page.keyboard.press("Tab");
  }

  await expect(locator).toBeFocused();
}
