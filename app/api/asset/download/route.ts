import { NextResponse } from "next/server";
import { connectToDatabase } from "@/lib/db";
import { validateLicense } from "@/lib/license";
import {
  GITHUB_PAT,
  getGithubApiUrl,
  getGithubRepo,
  isBetaMode,
} from "@/app/configs/github.config";

type GithubAsset = {
  id: number;
  name: string;
  browser_download_url?: string;
  size?: number;
};

type GithubRelease = {
  tag_name: string;
  assets?: GithubAsset[];
};

// GET: Download asset from GitHub after verifying license
export async function GET(req: Request) {
  try {
    await connectToDatabase();
    const { searchParams } = new URL(req.url);
    const licenseKey = searchParams.get("licenseKey");
    const machineCode = searchParams.get("machineCode");
    const installedVersion = searchParams.get("installedVersion") || searchParams.get("version");
    const beta = isBetaMode(searchParams);
    const GITHUB_API_URL = getGithubApiUrl(beta);
    const GITHUB_REPO = getGithubRepo(beta);
    
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

    // Validate required parameters
    if (!licenseKey || !machineCode) {
      return NextResponse.json(
        {
          status: false,
          error: "licenseKey and machineCode parameters are required",
        },
        { status: 400 }
      );
    }

    // License verification
    // Validate the license
    const validationResult = await validateLicense(
      licenseKey,
      machineCode,
      installedVersion || undefined,
      beta || false
    );
    if (!validationResult.valid) {
      return NextResponse.json(
        {
          status: false,
          error: validationResult.message || "License validation failed",
        },
        { status: 400 }
      );
    }

    // If validation returns an asset URL, use it for download
    if (validationResult.asset && validationResult.asset !== "NOT FOUND") {
      try {
        // Fetch the asset from the URL provided by license validation
        const assetResponse = await fetch(validationResult.asset, {
          headers: {
            Accept: "application/octet-stream",
            "User-Agent": "License-Admin-App",
            ...(GITHUB_PAT ? { Authorization: `Bearer ${GITHUB_PAT}` } : {}),
          },
          redirect: "follow",
        });

        if (!assetResponse.ok) {
          // Fall through to GitHub API method if browser_download_url doesn't work
          console.warn("Failed to download from browser_download_url, falling back to GitHub API");
        } else {
          // Get the filename
          let filename = "asset";
          const contentDisposition = assetResponse.headers.get("content-disposition");
          if (contentDisposition) {
            const filenameMatch = contentDisposition.match(
              /filename[^;=\n]*=((['"]).*?\2|[^;\n]*)/
            );
            if (filenameMatch && filenameMatch[1]) {
              filename = filenameMatch[1].replace(/['"]/g, "");
            }
          }

          // Extract filename from URL if not in headers
          if (filename === "asset" && validationResult.asset) {
            const urlParts = validationResult.asset.split("/");
            const lastPart = urlParts[urlParts.length - 1];
            if (lastPart && lastPart.includes(".")) {
              filename = lastPart.split("?")[0]; // Remove query params
            }
          }

          const contentType =
            assetResponse.headers.get("content-type") || "application/octet-stream";
          const contentLength = assetResponse.headers.get("content-length");
          
          // Stream the file back to the client instead of loading into memory
          return new NextResponse(assetResponse.body, {
            status: 200,
            headers: {
              "Content-Type": contentType,
              "Content-Disposition": `attachment; filename="${filename}"`,
              ...(contentLength ? { "Content-Length": contentLength } : {}),
            },
          });
        }
      } catch (error) {
        console.warn("Error downloading from asset URL, falling back to GitHub API:", error);
        // Fall through to GitHub API method
      }
    }

    // Fetch releases from GitHub
    if (!GITHUB_API_URL) {
      return NextResponse.json(
        { status: false, error: "Failed to determine GitHub API URL" },
        { status: 500 }
      );
    }

    const githubHeaders: Record<string, string> = {
      Accept: "application/vnd.github.v3+json",
      "User-Agent": "License-Admin-App",
    };

    if (GITHUB_PAT) {
      githubHeaders.Authorization = `Bearer ${GITHUB_PAT}`;
    }

    const githubResponse = await fetch(GITHUB_API_URL, {
      headers: githubHeaders,
    });

    if (!githubResponse.ok) {
      return NextResponse.json(
        { status: false, error: "Failed to fetch releases from GitHub" },
        { status: 500 }
      );
    }

    const releases = (await githubResponse.json()) as GithubRelease[];

    // Find the target release
    let targetRelease: GithubRelease | undefined;
    const versionToUse = installedVersion || searchParams.get("version");

    if (versionToUse) {
      // Find specific version
      targetRelease = releases.find((release) => {
        const releaseVersion = release.tag_name.replace(/^v/, "");
        return (
          releaseVersion === versionToUse ||
          release.tag_name === versionToUse ||
          release.tag_name === `v${versionToUse}`
        );
      });

      if (!targetRelease) {
        return NextResponse.json(
          { status: false, error: `Version ${versionToUse} not found` },
          { status: 404 }
        );
      }
    } else {
      // Get latest release (first in the array, as GitHub returns them sorted by date)
      if (releases.length === 0) {
        return NextResponse.json(
          { status: false, error: "No releases found" },
          { status: 404 }
        );
      }
      targetRelease = releases[0];
    }

    // Get the first available asset
    const assets = targetRelease.assets || [];
    if (assets.length === 0) {
      return NextResponse.json(
        {
          status: false,
          error: `No downloadable asset found for version ${targetRelease.tag_name}`,
        },
        { status: 404 }
      );
    }

    const asset = assets.find((a) => a.browser_download_url) || assets[0];
    if (!asset || !asset.id) {
      return NextResponse.json(
        { status: false, error: "Asset not available" },
        { status: 404 }
      );
    }

    // Use GitHub API endpoint to download the asset (browser_download_url doesn't work for programmatic access)
    if (!GITHUB_REPO) {
      return NextResponse.json(
        { status: false, error: "GitHub repository not configured" },
        { status: 500 }
      );
    }

    // Construct the GitHub API asset download URL
    const assetDownloadUrl = `https://api.github.com/repos/${GITHUB_REPO}/releases/assets/${asset.id}`;
    // Fetch the asset from GitHub API
    const downloadHeaders: Record<string, string> = {
      Accept: "application/octet-stream",
      "User-Agent": "License-Admin-App",
    };

    if (GITHUB_PAT) {
      downloadHeaders.Authorization = `Bearer ${GITHUB_PAT}`;
    }
    const assetResponse = await fetch(assetDownloadUrl, {
      headers: downloadHeaders,
      redirect: "follow", // Follow redirects
    });
    if (!assetResponse.ok) {
      return NextResponse.json(
        { status: false, error: "Failed to fetch asset from GitHub" },
        { status: assetResponse.status }
      );
    }

    // Get the filename
    let filename = asset.name;
    const contentDisposition = assetResponse.headers.get("content-disposition");
    if (contentDisposition) {
      const filenameMatch = contentDisposition.match(
        /filename[^;=\n]*=((['"]).*?\2|[^;\n]*)/
      );
      if (filenameMatch && filenameMatch[1]) {
        filename = filenameMatch[1].replace(/['"]/g, "");
      }
    }

    // Get the content type
    const contentType =
      assetResponse.headers.get("content-type") || "application/octet-stream";
    const contentLength = assetResponse.headers.get("content-length");

    // Stream the file back to the client instead of loading into memory
    return new NextResponse(assetResponse.body, {
      status: 200,
      headers: {
        "Content-Type": contentType,
        "Content-Disposition": `attachment; filename="${filename}"`,
        ...(contentLength ? { "Content-Length": contentLength } : {}),
      },
    });
  } catch (error: unknown) {
    console.error("Error downloading asset:", error);
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
