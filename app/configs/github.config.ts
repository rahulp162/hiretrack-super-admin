export const GITHUB_PAT = process.env.GITHUB_PAT;
export const GITHUB_REPO = process.env.GITHUB_REPO;
export const GITHUB_REPO_BETA = process.env.GITHUB_REPO_BETA;
export const GITHUB_REPO_STAGING = process.env.GITHUB_REPO_STAGING;

export const GITHUB_API_URL = GITHUB_REPO
  ? `https://api.github.com/repos/${GITHUB_REPO}/releases`
  : null;
export const GITHUB_API_URL_BETA = GITHUB_REPO_BETA
  ? `https://api.github.com/repos/${GITHUB_REPO_BETA}/releases`
  : null;
export const GITHUB_API_URL_STAGING = GITHUB_REPO_STAGING
  ? `https://api.github.com/repos/${GITHUB_REPO_STAGING}/releases`
  : null;

export type GithubChannel = "production" | "beta" | "staging";

/**
 * Get channel from request query params.
 * If neither staging nor beta is set, returns production (default).
 * Staging takes precedence over beta if both are set.
 */
export function getChannel(searchParams: URLSearchParams): GithubChannel {
  const staging = searchParams.get("staging") || searchParams.get("STAGING");
  const beta = searchParams.get("beta") || searchParams.get("BETA");
  const isStaging = staging === "true" || staging === "1";
  const isBeta = beta === "true" || beta === "1";
  if (isStaging) return "staging";
  if (isBeta) return "beta";
  return "production";
}

/**
 * Get GitHub releases API URL for the given channel.
 * Returns null if the channel is non-production and its repo is not configured.
 */
export function getGithubApiUrl(channel: GithubChannel): string | null {
  switch (channel) {
    case "staging":
      return GITHUB_REPO_STAGING
        ? `https://api.github.com/repos/${GITHUB_REPO_STAGING}/releases`
        : null;
    case "beta":
      return GITHUB_REPO_BETA
        ? `https://api.github.com/repos/${GITHUB_REPO_BETA}/releases`
        : null;
    case "production":
    default:
      return GITHUB_REPO
        ? `https://api.github.com/repos/${GITHUB_REPO}/releases`
        : null;
  }
}

/**
 * Get GitHub repo (owner/name) for the given channel.
 */
export function getGithubRepo(channel: GithubChannel): string | undefined {
  switch (channel) {
    case "staging":
      return GITHUB_REPO_STAGING;
    case "beta":
      return GITHUB_REPO_BETA;
    case "production":
    default:
      return GITHUB_REPO;
  }
}

/** Human-readable label for error messages */
export function getChannelLabel(channel: GithubChannel): string {
  switch (channel) {
    case "staging":
      return "Staging";
    case "beta":
      return "Beta";
    case "production":
    default:
      return "Production";
  }
}

/** Env var name for the channel (for error messages) */
export function getChannelEnvVar(channel: GithubChannel): string {
  switch (channel) {
    case "staging":
      return "GITHUB_REPO_STAGING";
    case "beta":
      return "GITHUB_REPO_BETA";
    case "production":
    default:
      return "GITHUB_REPO";
  }
}
