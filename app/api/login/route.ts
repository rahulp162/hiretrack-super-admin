import { NextResponse } from "next/server";
import bcrypt from "bcryptjs";
import { Admin } from "../../models/admin";
import { connectToDatabase } from "@/lib/db";
import { withAuthCookie, signAdminJwtJose } from "@/lib/auth";
import { checkRateLimit } from "@/lib/ratelimit";

const LOGIN_RATE_LIMIT_CONFIG = {
  maxRequests: 10,
  windowMs: 60 * 1000,
};

function normalizeEmail(email: unknown): string {
  return typeof email === "string" ? email.trim().toLowerCase() : "";
}

function getClientIP(req: Request): string {
  const forwardedFor = req.headers.get("x-forwarded-for")?.split(",")[0]?.trim();
  const realIP = req.headers.get("x-real-ip")?.trim();
  const cloudflareIP = req.headers.get("cf-connecting-ip")?.trim();
  const flyClientIP = req.headers.get("fly-client-ip")?.trim();
  const vercelForwardedFor = req.headers.get("x-vercel-forwarded-for")?.trim();
  const ip =
    forwardedFor || cloudflareIP || flyClientIP || vercelForwardedFor || realIP || "127.0.0.1";
  return ip.replace(/^::ffff:/, "");
}

// POST: Admin login
export async function POST(req: Request) {
  try {
    const body = await req.json();
    const email = normalizeEmail(body?.email);
    const password = body?.password;
    const clientIP = getClientIP(req);
    const rateLimitKey = `login:${email || "unknown"}:${clientIP}`;
    const rateLimitResult = checkRateLimit(rateLimitKey, LOGIN_RATE_LIMIT_CONFIG);

    if (!rateLimitResult.success) {
      return NextResponse.json(
        {
          error: "Rate limit exceeded",
          message: `Too many login attempts. Please try again after ${rateLimitResult.retryAfter} seconds.`,
          retryAfter: rateLimitResult.retryAfter,
        },
        {
          status: 429,
          headers: {
            "X-RateLimit-Limit": rateLimitResult.limit.toString(),
            "X-RateLimit-Remaining": rateLimitResult.remaining.toString(),
            "X-RateLimit-Reset": new Date(rateLimitResult.reset).toISOString(),
            "Retry-After": rateLimitResult.retryAfter?.toString() || "60",
          },
        }
      );
    }

    await connectToDatabase();

    // Find admin by email
    const admin = await Admin.findOne({ email });
    if (!admin) {
      return NextResponse.json(
        { error: "Invalid credentials" },
        { status: 401 }
      );
    }

    // Compare passwords
    const isPasswordValid = await bcrypt.compare(password, admin.password);
    if (!isPasswordValid) {
      return NextResponse.json(
        { error: "Invalid credentials" },
        { status: 401 }
      );
    }

    // Generate JWT token using jose
    const token = await signAdminJwtJose({
      adminId: admin._id.toString(),
      email: admin.email,
    });

    // Create response with token in body
    const response = NextResponse.json({
      success: true,
      token,
      user: {
        id: admin._id,
        email: admin.email,
        name: admin.name,
      },
    });

    // Set the auth cookie
    return withAuthCookie(response, token);
  } catch (error: unknown) {
    return NextResponse.json(
      {
        error: "Internal server error",
        message: error instanceof Error ? error.message : "Unknown error",
      },
      { status: 500 }
    );
  }
}
