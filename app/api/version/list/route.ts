import { GITHUB_PAT, getGithubApiUrl, isBetaMode } from "@/app/configs/github.config";
import { NextResponse } from "next/server";

// Utility function to compare semantic versions
function compareVersions(a: string, b: string) {
  const pa = a.split(".").map(Number);
  const pb = b.split(".").map(Number);

  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const diff = (pa[i] || 0) - (pb[i] || 0);
    if (diff !== 0) return diff;
  }
  return 0;
}

// Check if version lies between currentVersion and upgradeVersion
function isVersionInRange(version: string, currentVersion?: string, upgradeVersion?: string) {
  if (!currentVersion && !upgradeVersion) return true;

  const v = version.split(".").map(Number);
  const current = currentVersion?.split(".").map(Number) || [];
  const upgrade = upgradeVersion?.split(".").map(Number) || [];

  const compare = (a: number[], b: number[]) => {
    for (let i = 0; i < Math.max(a.length, b.length); i++) {
      const diff = (a[i] || 0) - (b[i] || 0);
      if (diff !== 0) return diff;
    }
    return 0;
  };

  if (currentVersion && compare(v, current) < 0) return false; // version < current
  if (upgradeVersion && compare(v, upgrade) > 0) return false; // version > upgrade
  return true;
}

// GET: List all available versions from GitHub releases
export async function GET(req: Request) {
  try {
    const { searchParams } = new URL(req.url);
    const currentVersion = searchParams.get("currentVersion");
    const upgradeVersion = searchParams.get("upgradeVersion");
    const beta = isBetaMode(searchParams);
    const GITHUB_API_URL = getGithubApiUrl(beta);

    // Debug logging
    console.log("🔍 Version List API - Beta mode:", beta);
    console.log("🔍 Beta param from URL:", searchParams.get("beta"), searchParams.get("BETA"));
    console.log("🔍 GitHub API URL:", GITHUB_API_URL);
    console.log("🔍 GITHUB_REPO_BETA:", process.env.GITHUB_REPO_BETA);

    // Check if beta mode is requested but not configured
    if (beta && !GITHUB_API_URL) {
      return NextResponse.json(
        { 
          error: "Beta mode requested but GITHUB_REPO_BETA is not configured",
          message: "Please set GITHUB_REPO_BETA environment variable to enable beta releases"
        },
        { status: 400 }
      );
    }

    if (!GITHUB_API_URL) {
      return NextResponse.json(
        { error: "Failed to determine GitHub API URL" },
        { status: 500 }
      );
    }

    const githubResponse = await fetch(
      GITHUB_API_URL,
      {
        headers: {
          Accept: "application/vnd.github.v3+json",
          "User-Agent": "License-Admin-App",
          Authorization: `Bearer ${GITHUB_PAT}`,
        },
      }
    );

    if (!githubResponse.ok) {
      return NextResponse.json(
        { error: "Failed to fetch releases from GitHub" },
        { status: 500 }
      );
    }

    const releases = await githubResponse.json();

    let versions = releases.map((release: any) => {
      const version = release.tag_name.replace(/^v/, "");
      const assets = release.assets || [];

      const platforms: string[] = [];
      if (assets.some((a: any) => a.name.toLowerCase().includes(".exe") || a.name.toLowerCase().includes("windows"))) platforms.push("windows");
      if (assets.some((a: any) => a.name.toLowerCase().includes(".dmg") || a.name.toLowerCase().includes("mac"))) platforms.push("mac");
      if (assets.some((a: any) => a.name.toLowerCase().includes(".deb") || a.name.toLowerCase().includes(".rpm") || a.name.toLowerCase().includes("linux"))) platforms.push("linux");

      let migrationScriptUrl = null;
      const migrationAsset = assets.find((asset: any) =>
        asset.name.includes("migrationScriptUrl")
      );
      if (migrationAsset) {
        migrationScriptUrl = migrationAsset.browser_download_url;
      }

      const asset = assets[0]?.browser_download_url || null;

      return {
        version,
        tagName: release.tag_name,
        platforms,
        publishedAt: release.published_at,
        isPrerelease: release.prerelease,
        isDraft: release.draft,
        releaseNotes: release.body,
        releaseUrl: release.html_url,
        assetCount: assets.length,
        asset,
        migrationScriptUrl,
      };
    });

    // ✅ Apply version range filter if provided
    if (currentVersion || upgradeVersion) {
      versions = versions
        .filter((v: any) => isVersionInRange(v.version, currentVersion!, upgradeVersion!))
        // ✅ Sort ascending only when filters exist
        .sort((a: any, b: any) => compareVersions(a.version, b.version));
    }

    return NextResponse.json({
      totalVersions: versions.length,
      latestVersion: versions[0]?.version || null,
      versions,
    });
  } catch (error) {
    console.error("Error fetching version list:", error);
    return NextResponse.json(
      {
        error: "Internal server error",
        details: error instanceof Error ? error.message : "Unknown error",
      },
      { status: 500 }
    );
  }
}
