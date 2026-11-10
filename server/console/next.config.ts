import type { NextConfig } from "next";

// Production: static export embedded in the Go binary, served at /console.
// Development (`npm run dev`): API calls are proxied to the Go server.
const api = process.env.MYTERMI_API ?? "http://127.0.0.1:8080";
const dev = process.env.NODE_ENV === "development";

const config: NextConfig = {
  basePath: "/console",
  trailingSlash: true,
  images: { unoptimized: true },
  ...(dev
    ? { rewrites: async () => [{ source: "/api/:path*", destination: `${api}/api/:path*`, basePath: false }] }
    : { output: "export" }),
};

export default config;
