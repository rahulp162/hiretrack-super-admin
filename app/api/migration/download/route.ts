import { NextResponse } from "next/server";
import { GITHUB_PAT, getGithubApiUrl, isBetaMode } from "@/app/configs/github.config";

type GithubAsset = {
  name: string;
  browser_download_url?: string;
  url?: string;
};

type GithubRelease = {
  tag_name: string;
  assets?: GithubAsset[];
  published_at: string;
};

function findMigrationAsset(assets: GithubAsset[] = []) {
  console.log("assets", assets);
  return assets.find((a) =>
    a.name.toLowerCase().includes("migrationscripturl") || a.name.toLowerCase().includes("migrationScriptUrl")
  );
}

function compareVersions(a: string, b: string) {
  const pa = a.split(".").map(Number);
  const pb = b.split(".").map(Number);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const diff = (pa[i] || 0) - (pb[i] || 0);
    if (diff !== 0) return diff;
  }
  return 0;
}

function isVersionInRange(
  releaseTag: string,
  currentVersion?: string | null,
  requiredVersion?: string | null
) {
  const version = releaseTag.replace(/^v/, "");
  const current = currentVersion?.replace(/^v/, "");
  const required = requiredVersion?.replace(/^v/, "");

  if (current && compareVersions(version, current) < 0) return false;
  if (required && compareVersions(version, required) > 0) return false;
  return true;
}

function normalizeVersionMatch(release: GithubRelease, version?: string | null) {
  if (!version) return true;
  const clean = version.replace(/^v/, "");
  const tag = release.tag_name.replace(/^v/, "");
  return tag === clean || release.tag_name === version;
}

export async function GET(req: Request) {
  try {
    const { searchParams } = new URL(req.url);
    const requestedVersion = searchParams.get("version");
    const currentVersion = searchParams.get("currentVersion");
    const requiredVersion =
      searchParams.get("requiredVersion") || searchParams.get("upgradeVersion");
    const beta = isBetaMode(searchParams);
    const GITHUB_API_URL = getGithubApiUrl(beta);

    // Check if beta mode is requested but not configured
    if (beta && !GITHUB_API_URL) {
      return NextResponse.json(
        { 
          status: false,
          error: "Beta mode requested but GITHUB_REPO_BETA is not configured",
          message: "Please set GITHUB_REPO_BETA environment variable to enable beta releases"
        },
        { status: 400 }
      );
    }

    if (!GITHUB_API_URL) {
      return NextResponse.json(
        { status: false, error: "Failed to determine GitHub API URL" },
        { status: 500 }
      );
    }

    const headers: Record<string, string> = {
      Accept: "application/vnd.github.v3+json",
      "User-Agent": "License-Admin-App",
    };
    if (GITHUB_PAT) {
      headers.Authorization = `Bearer ${GITHUB_PAT}`;
    }

    const releasesRes = await fetch(GITHUB_API_URL, { headers });
    if (!releasesRes.ok) {
      return NextResponse.json(
        { status: false, error: "Failed to fetch releases from GitHub" },
        { status: 500 }
      );
    }

    const releases = (await releasesRes.json()) as GithubRelease[];
    if (!Array.isArray(releases) || releases.length === 0) {
      return NextResponse.json(
        { status: false, error: "No releases found" },
        { status: 404 }
      );
    }

    // Filter releases within range when current/required provided
    let targetReleases: GithubRelease[] = releases;

    if (currentVersion || requiredVersion) {
      targetReleases = releases.filter((r) =>
        isVersionInRange(r.tag_name, currentVersion, requiredVersion)
      );
    } else if (requestedVersion) {
      const match = releases.find((r) => normalizeVersionMatch(r, requestedVersion));
      targetReleases = match ? [match] : [];
    } else {
      // default: latest only
      targetReleases = releases.slice(0, 1);
    }
    // console.log("targetReleases", targetReleases);
    if (!targetReleases.length) {
      return NextResponse.json(
        {
          status: false,
          error: `Version range not found (${
            requestedVersion || `${currentVersion || "N/A"} -> ${requiredVersion || "latest"}`
          })`,
        },
        { status: 404 }
      );
    }

    // Collect migration scripts across target releases (sorted ascending by version)
    const normalized = targetReleases
      .map((r) => ({
        release: r,
        version: r.tag_name.replace(/^v/, ""),
      }))
      .sort((a, b) => compareVersions(a.version, b.version));

    const migrations: Array<{
      version: string;
      fileName: string;
      contentBase64: string;
      size: number;
      contentType: string;
    }> = [];
    // console.log("normalized", normalized);  
    for (const entry of normalized) {
      const migrationAsset = findMigrationAsset(entry.release.assets || []);
      console.log("migrationAsset", migrationAsset);
      if (!migrationAsset || !migrationAsset.browser_download_url) {
        continue;
      }
      const githubHeaders: Record<string, string> = {
        // GitHub requires the API asset endpoint plus this Accept to serve the binary stream.
        Accept: "application/octet-stream",
        "User-Agent": "License-Admin-App",
      };

      if (GITHUB_PAT) {
        githubHeaders.Authorization = `Bearer ${GITHUB_PAT}`;
      }

      // For private assets, browser_download_url returns 404 even with a PAT.
      // Use the API asset URL when a PAT is present; otherwise fall back to the public URL.
      const assetUrl =
        GITHUB_PAT && migrationAsset.url
          ? migrationAsset.url
          : migrationAsset.browser_download_url;

      if (!assetUrl) {
        continue;
      }

      const assetRes = await fetch(assetUrl, {
        headers: githubHeaders,
      });
      console.log("assetRes", assetRes);
      if (!assetRes.ok) {
        return NextResponse.json(
          {
            status: false,
            error: `Failed to download migration script for version ${entry.version}`,
          },
          { status: assetRes.status }
        );
      }

      const buffer = Buffer.from(await assetRes.arrayBuffer());
      const fileName = migrationAsset.name || "migrationScriptUrl.cjs";
      const contentType =
        assetRes.headers.get("content-type") || "application/octet-stream";

      migrations.push({
        version: entry.version,
        fileName,
        contentBase64: buffer.toString("base64"),
        size: buffer.length,
        contentType,
      });
    }

    return NextResponse.json({
      status: true,
      currentVersion: currentVersion || null,
      requiredVersion: requiredVersion || null,
      migrations,
      
    });
  } catch (error: unknown) {
    console.error("Error downloading migration script:", error);
    return NextResponse.json(
      {
        status: false,
        error: "Internal server error",
        message: error instanceof Error ? error.message : "Unknown error",
      },
      { status: 500 }
    );
  }
}
