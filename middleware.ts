import { NextResponse } from "next/server";
import type { NextRequest } from "next/server";
import { COOKIE_NAME, verifyAdminJwt } from "./lib/auth";

// List of public API routes that don't require authentication
const publicApiRoutes = [
  "/api/login",
  "/api/logout",
  "/api/register",
  "/api/license/create",
  "/api/license/validate",
  "/api/license/register",
  "/api/version",
  "/api/license/update",
  "/api/license/generate",
  "/api/license/verify",
  "/api/asset/download",
  "/api/migration/download",
  "/api/get-ip",
];

// List of public pages that don't require authetication
const publicPages = ["/", "/register"];

export async function middleware(request: NextRequest) {
  const { pathname } = request.nextUrl;

  // Allow public API routes without authentication
  if (publicApiRoutes.some((route) => pathname.startsWith(route))) {
    return NextResponse.next();
  }

  // Allow public pages without authentication
  if (publicPages.includes(pathname)) {
    return NextResponse.next();
  }

  // For both API and non-API routes, check for auth cookie
  const token = request.cookies.get(COOKIE_NAME)?.value;

  // If API route and no token, return 401
  if (pathname.startsWith("/api")) {
    if (!token) {
      return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
    }
    try {
      const payload = await verifyAdminJwt(token);
      if (!payload) {
        return NextResponse.json({ error: "Invalid token" }, { status: 401 });
      }
    } catch (error) {
      return NextResponse.json(
        { error: "Invalid token", details: "Token verification failed" },
        { status: 401 }
      );
    }
    return NextResponse.next();
  }

  // For non-API routes (pages), check for auth cookie
  // If no token and trying to access protected route, redirect to login
  if (!token && pathname.startsWith("/dashboard")) {
    return NextResponse.redirect(new URL("/", request.url));
  }

  // If there is a token, verify it
  if (token) {
    try {
      const payload = await verifyAdminJwt(token);

      // If invalid token and trying to access protected route, redirect to login
      if (!payload && pathname.startsWith("/dashboard")) {
        return NextResponse.redirect(new URL("/", request.url));
      }
    } catch (error) {
      // If token verification fails, redirect to login
      if (pathname.startsWith("/dashboard")) {
        return NextResponse.redirect(new URL("/", request.url));
      }
    }
  }

  return NextResponse.next();
}

// Configure the middleware to run on specific paths
export const config = {
  matcher: [
    // Match all API routes
    "/api/:path*",
    // Match all dashboard routes
    "/dashboard/:path*",
    // Match root and register page
    "/",
    "/register",
  ],
};
