import { bindings, defineConfig, exports as workerExports } from "cf/config";

export default defineConfig({
  accountId: "16145c40b55b1a5995ba897da48f0546",
  worker: {
    name: "debian-ci-webhook",
    compatibilityDate: "2026-10-06",
    entrypoint: "./worker.mjs",
    workersDev: true,
    previewUrls: false,
    env: {
      ROUTES_JSON: bindings.text(JSON.stringify({
        "slopization/lt6911-of": { branch: "master", ref: "main" },
        "slopization/firmware-cnm-wave420l": { branch: "master", ref: "main" },
        "slopization/u-boot-cv181x": { branch: "master", ref: "main" },
        "slopization/linux-cv181x-sodoport": { branch: "*", ref: "main", tags: false },
      })),
      GITHUB_APP_ID: bindings.secret(),
      GITHUB_APP_PRIVATE_KEY: bindings.secret(),
      WEBHOOK_SECRET: bindings.secret(),
      DELIVERIES: bindings.durableObject({ worker: "debian-ci-webhook", exportName: "Delivery" }),
    },
    exports: { Delivery: workerExports.durableObject({ storage: "sqlite" }) },
  },
});
