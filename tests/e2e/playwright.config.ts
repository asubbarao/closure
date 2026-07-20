import { defineConfig, devices } from "@playwright/test";

/**
 * Closure e2e — drives the live DuckDB/quackapi app at :8117.
 * Boot the app first (see README.md). Tests do not start the server.
 */
const baseURL = process.env.CLOSURE_BASE_URL || "http://127.0.0.1:8117";

export default defineConfig({
  testDir: "./specs",
  fullyParallel: false,
  workers: 1,
  retries: 0,
  timeout: 60_000,
  expect: { timeout: 15_000 },
  reporter: [["list"], ["html", { open: "never", outputFolder: "playwright-report" }]],
  use: {
    baseURL,
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    video: "off",
    actionTimeout: 15_000,
    navigationTimeout: 30_000,
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
});
