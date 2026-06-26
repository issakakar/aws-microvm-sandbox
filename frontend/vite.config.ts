import { defineConfig } from "vite";

// Plain static SPA build (output: dist/). The app is hosted on S3 behind
// CloudFront; the /api/* calls go to CloudFront cache behaviors (OAC SigV4 →
// provisioner Lambda URLs), so no dev server proxy is wired here; use the
// deployed CloudFront URL to test.
export default defineConfig({
  build: {
    target: "es2022",
  },
});
