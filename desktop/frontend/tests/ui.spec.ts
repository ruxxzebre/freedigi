import { test, expect } from "@playwright/test";
test("browser preview is honest, navigation has full hit areas, and credits are visible", async ({
  page,
}) => {
  await page.goto("/");
  await expect(
    page.getByText("Browser preview — hardware is unavailable.", {
      exact: false,
    }),
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Start monitoring" }),
  ).toBeDisabled();
  await page
    .getByRole("button", { name: "Button mapping", exact: true })
    .click({ position: { x: 180, y: 23 } });
  await expect(
    page.getByRole("heading", { name: "Start with what’s on your controller" }),
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Read active profile" }),
  ).toBeDisabled();
  await page
    .getByRole("button", { name: "About", exact: true })
    .click({ position: { x: 3, y: 23 } });
  await expect(
    page.getByText("ControlLab Swift controller app by dracinn"),
  ).toBeVisible();
  await expect(
    page.getByRole("link", { name: "Original ControlLab project" }),
  ).toHaveAttribute("href", "https://github.com/dracinn/ControlLab");
  await page.getByRole("button", { name: "Overview", exact: true }).click();
  await page.screenshot({ path: "/tmp/freedigi-overview.png", fullPage: true });
});
test("mapping requires a read, previews retain edits, and live applies clear verified edits", async ({
  page,
}) => {
  await page.addInitScript(() => {
    const state: any = {
      devices: [
        {
          path: "/dev/test",
          name: "Simulated test controller",
          product: "2401",
          accessible: true,
        },
      ],
      path: "/dev/test",
      dryRun: true,
      monitoring: false,
      monitorWanted: false,
      input: null,
      data: {},
      logs: [],
      busy: "",
      error: "",
      build: "UI test only",
    };
    (window as any).operations = [];
    (window as any).go = {
      main: {
        App: {
          Status: async () => structuredClone(state),
          Refresh: async () => structuredClone(state),
          SetDryRun: async (v: boolean) => {
            state.dryRun = v;
            return structuredClone(state);
          },
          Select: async () => structuredClone(state),
          Perform: async (action: string, params: any) => {
            (window as any).operations.push({
              action,
              params,
              dryRun: state.dryRun,
            });
            if (action === "profileRead") {
              state.data = {
                snapshot: {},
                title: "Test profile",
                slot: 1,
                mappings: Object.fromEntries(
                  Array.from({ length: 22 }, (_, i) => [i, i]),
                ),
              };
              return structuredClone(state.data);
            }
            if (action === "profileApply") {
              if (state.dryRun)
                return { preview: true, message: "Plan validated. No writes." };
              state.data.mappings = {
                ...state.data.mappings,
                ...params.mappings,
              };
              return structuredClone(state.data);
            }
            return {};
          },
        },
      },
    };
  });
  await page.goto("/");
  await page
    .getByRole("button", { name: "Button mapping", exact: true })
    .click();
  await expect(page.getByLabel("Map M1 to", { exact: true })).toHaveCount(0);
  await page.getByRole("button", { name: "Read active profile" }).click();
  await page.getByLabel("Map M1 to", { exact: true }).selectOption("4");
  await page.getByLabel("Map M2 to", { exact: true }).selectOption("7");
  await expect(page.getByText("Profile 1 · 2 staged changes")).toBeVisible();
  await page.getByRole("button", { name: "Preview save", exact: true }).click();
  await expect(page.getByText("Plan validated. No writes.")).toBeVisible();
  await expect(page.getByText("Profile 1 · 2 staged changes")).toBeVisible();
  await page.getByRole("switch", { name: "Dry run", exact: true }).click();
  await page
    .getByRole("button", { name: "Save to controller", exact: true })
    .click();
  await expect(page.getByText("Profile 1 · 0 staged changes")).toBeVisible();
  const ops = await page.evaluate(() => (window as any).operations);
  expect(ops).toEqual([
    { action: "profileRead", params: {}, dryRun: true },
    {
      action: "profileApply",
      params: { mappings: { 18: 4, 19: 7 }, persist: true },
      dryRun: true,
    },
    {
      action: "profileApply",
      params: { mappings: { 18: 4, 19: 7 }, persist: true },
      dryRun: false,
    },
  ]);
});
