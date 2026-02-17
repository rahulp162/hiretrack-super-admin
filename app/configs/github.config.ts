export const GITHUB_PAT = process.env.GITHUB_PAT; 
export const GITHUB_REPO = process.env.GITHUB_REPO;
export const GITHUB_REPO_BETA = process.env.GITHUB_REPO_BETA;
export const GITHUB_API_URL = `https://api.github.com/repos/${GITHUB_REPO}/releases`;
export const GITHUB_API_URL_BETA = GITHUB_REPO_BETA 
  ? `https://api.github.com/repos/${GITHUB_REPO_BETA}/releases`
  : `https://api.github.com/repos/${GITHUB_REPO}/releases`; // Fallback to production if beta repo not set

// Helper function to get GitHub API URL based on beta mode
// Returns null if beta mode is requested but GITHUB_REPO_BETA is not configured
export function getGithubApiUrl(isBeta: boolean): string | null {
  if (isBeta) {
    if (!GITHUB_REPO_BETA) {
      return null; // Beta requested but not configured
    }
    return `https://api.github.com/repos/${GITHUB_REPO_BETA}/releases`;
  }
  return `https://api.github.com/repos/${GITHUB_REPO}/releases`;
}

// Helper function to get GitHub repo based on beta mode
export function getGithubRepo(isBeta: boolean): string | undefined {
  return isBeta ? GITHUB_REPO_BETA : GITHUB_REPO;
}

// Helper function to check if beta mode is enabled from request
export function isBetaMode(searchParams: URLSearchParams): boolean {
  const beta = searchParams.get("beta") || searchParams.get("BETA");
  return beta === "true" || beta === "1";
}
