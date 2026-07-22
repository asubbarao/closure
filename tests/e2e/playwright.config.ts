import { defineConfig, devices } from "@playwright/test";

/**
 * Thin-stack e2e — live DuckDB/quackapi app.
 * Boot first (make run / make test). Specs do not start the server.
 */
const baseURL = process.env.CLOSURE_BASE_URL || "http://127.0.0.1:8117";

export default defineConfig({
  testDir: "./specs",
  fullyParallel: false,
  workers: 1,
  retries: 0,
  timeout: 90_000,
  expect: { timeout: 25_000 },
  reporter: [["list"], ["html", { open: "never", outputFolder: "playwright-report" }]],
  use: {
    baseURL,
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    video: "off",
    actionTimeout: 20_000,
    navigationTimeout: 45_000,
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
});
