import crypto from "crypto";
import License from "@/app/models/license";
import Client from "@/app/models/client";
import ValidationHistory from "@/app/models/validationHistory";
import { connectToDatabase } from "./db";
import type { GithubChannel } from "@/app/configs/github.config";
import { getChannelLabel, getGithubApiUrl, GITHUB_PAT } from "@/app/configs/github.config";

// Generate a unique license key
export function generateLicenseKey(email: string, machineCode: string): string {
  const secret = process.env.LICENSE_SECRET || "development-secret";

  // Add cryptographically random salt (nonce)
  const nonce = crypto.randomBytes(8).toString("hex"); // 16 hex chars
  
  const hmac = crypto.createHmac("sha256", secret);
  // hmac.update(`${email}:${machineCode}`);
  hmac.update(`${email}:${machineCode}:${nonce}`);
  const digest = hmac.digest("hex");
  // Format in blocks for readability XXXX-XXXX-...
  // Compose key = nonce + truncated digest
  const raw = `${nonce}${digest.slice(0, 24)}`.toUpperCase(); // shorter key, still strong

  // Format into XXXX-XXXX-... blocks for readability
  return raw.match(/.{1,4}/g)!.join("-");
}

export function safeJson<T>(value: unknown): T {
  return value as T;
}

/**
 * Verify a given license key.
 * Returns { valid: boolean, reason?: string, nonce?: string }
 */
export function verifyLicenseKey(
  key: string,
  email: string,
  machineCode: string
): { valid: boolean; reason?: string; nonce?: string } {
  if (!key) return { valid: false, reason: "no key provided" };
  if (!email || !machineCode)
    return { valid: false, reason: "email/machineCode missing" };

  const raw = key.replace(/-/g, "").toLowerCase();
  const secret = process.env.LICENSE_SECRET || "development-secret";
  // Nonce = first 16 hex chars (8 bytes)
  const nonce = raw.slice(0, 16);
  const signature = raw.slice(16);

  if (raw.length < 40) {
    return { valid: false, reason: "invalid key length" };
  }

  // Recompute expected signature
  const hmac = crypto.createHmac("sha256", secret);
  hmac.update(`${email}:${machineCode}:${nonce}`);
  const expectedSig = hmac.digest("hex").slice(0, 24);

  // Constant-time comparison
  const a = Buffer.from(signature, "hex");
  const b = Buffer.from(expectedSig, "hex");
  const equal = a.length === b.length && crypto.timingSafeEqual(a, b);

  return equal
    ? { valid: true, nonce }
    : { valid: false, reason: "signature mismatch", nonce };
}
// Validate if a license is valid based on multiple criteria
// Validate if a license is valid based on email and machine code
export async function validateLicense(
  email: string,         // 👈 1. Changed from licenseKey to email
  machineCode: string,
  installedVersion?: string,
  channel: GithubChannel = "production"
): Promise<{
  valid: boolean;
  asset?: string;
  message?: string;
  licenseData?: unknown;
}> {
  let license: typeof License.prototype | null = null;
  let validationResult: {
    valid: boolean;
    asset?: string;
    message?: string;
  } = {
    valid: false,
    message: "",
  };

  try {
    const GITHUB_API_URL = getGithubApiUrl(channel);
    if (!GITHUB_API_URL) {
      validationResult = {
        valid: false,
        message: `${getChannelLabel(channel)} mode requested but the corresponding GitHub repo is not configured`,
      };
      return validationResult;
    }
    await connectToDatabase();
    
    // 👇 2. Find the license using the Email and Machine Code combo
    license = await License.findOne({ 
      email: email, 
      machineCode: machineCode,
      status: { $ne: "revoked" }
    });

    if (!license) {
      validationResult = { valid: false, message: "Valid active license not found for this server." };
      // Log failed validation
      await ValidationHistory.create({
        licenseKey: "UNKNOWN", 
        email: email,
        machineCode,
        valid: false,
        message: "License not found or hardware mismatch",
        installedVersion,
      });
      return validationResult;
    }

    // Verify client exists and is active
    const client = await Client.findOne({ email: license.email });
    if (!client) {
      validationResult = {
        valid: false,
        message: "No client is registered with this email",
      };
      await ValidationHistory.create({
        licenseKey: license.licenseKey,
        email: license.email,
        machineCode,
        valid: false,
        message: "No client is registered with this email",
        installedVersion,
        licenseId: license._id.toString(),
      });
      return validationResult;
    }

    if (client.status !== "active") {
      validationResult = {
        valid: false,
        message: `Client status is ${client.status}`,
      };
      await ValidationHistory.create({
        licenseKey: license.licenseKey,
        email: license.email,
        machineCode,
        valid: false,
        message: `Client status is ${client.status}`,
        installedVersion,
        licenseId: license._id.toString(),
      });
      return validationResult;
    }

    // Update installed version if provided
    if (installedVersion && installedVersion !== license.installedVersion) {
      license.installedVersion = installedVersion;
    }

    // Update last validated timestamp
    license.lastValidatedAt = new Date();
    await license.save();

    // Log successful validation
    await ValidationHistory.create({
      licenseKey: license.licenseKey,
      email: license.email,
      machineCode,
      valid: true,
      installedVersion,
      licenseId: license._id.toString(),
    });

    // 👇 3. Fetch the asset from GitHub releases (Unchanged!) 👇
    let assetUrl: string | undefined = undefined;
    try {
      const githubHeaders: Record<string, string> = {
        Accept: "application/vnd.github.v3+json",
        "User-Agent": "License-Admin-App",
      };

      if (GITHUB_PAT) {
        githubHeaders.Authorization = `Bearer ${GITHUB_PAT}`;
      }

      const response = await fetch(GITHUB_API_URL, { headers: githubHeaders });
      if (!response.ok) {
        throw new Error("Failed to fetch release data from GitHub");
      }
      const releases = (await response.json()) as Array<{
        tag_name: string;
        assets?: Array<{ browser_download_url?: string }>;
      }>;

      let release: (typeof releases)[0] | undefined;
      if (installedVersion) {
        release =
          releases.find(
            (r) =>
              r.tag_name === installedVersion ||
              r.tag_name === `v${installedVersion}` ||
              r.tag_name === installedVersion.replace(/^v/, "")
          ) ||
          releases.find(
            (r) =>
              r.tag_name === `v${installedVersion}` ||
              r.tag_name === installedVersion
          );
      }
      if (
        (!release || !release.assets || release.assets.length === 0) &&
        Array.isArray(releases) &&
        releases.length > 0
      ) {
        release = releases[0];
      }

      if (
        release &&
        Array.isArray(release.assets) &&
        release.assets.length > 0
      ) {
        const asset = release.assets.find((a) => a.browser_download_url);
        if (asset) {
          assetUrl = asset.browser_download_url;
        }
      }
    } catch {
      assetUrl = undefined;
    }

    validationResult = {
      valid: true,
      asset: assetUrl || "NOT FOUND",
    };
    return validationResult;
  } catch {
    try {
      await ValidationHistory.create({
        licenseKey: license?.licenseKey || "UNKNOWN",
        email: email,
        machineCode,
        valid: false,
        message: "Error validating license",
        installedVersion,
        licenseId: license?._id?.toString(),
      });
    } catch {
      // Ignore history logging errors
    }
    return { valid: false, message: "Error validating license" };
  }
}