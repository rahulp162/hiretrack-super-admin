import { NextResponse } from "next/server";
import bcrypt from "bcryptjs";
import { Admin } from "../../models/admin";
import { connectToDatabase } from "@/lib/db";
import { cookies } from "next/headers";
import { COOKIE_NAME, verifyAdminJwtNode } from "@/lib/auth";
import { checkRateLimit } from "@/lib/ratelimit";

const REGISTER_RATE_LIMIT_CONFIG = {
  maxRequests: 5,
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

async function isAuthenticatedAdmin(): Promise<boolean> {
  const token = (await cookies()).get(COOKIE_NAME)?.value;
  if (!token) return false;

  const payload = verifyAdminJwtNode(token);
  if (!payload?.adminId) return false;

  const requestingAdmin = await Admin.findById(payload.adminId);
  return Boolean(requestingAdmin);
}

// GET: Register access status (bootstrap or authenticated admin)
export async function GET() {
  try {
    await connectToDatabase();
    const adminCount = await Admin.countDocuments();

    if (adminCount === 0) {
      return NextResponse.json({ canAccessRegister: true, bootstrapMode: true });
    }

    const authenticated = await isAuthenticatedAdmin();
    return NextResponse.json(
      { canAccessRegister: authenticated, bootstrapMode: false },
      { status: authenticated ? 200 : 401 }
    );
  } catch (error: any) {
    return NextResponse.json(
      { error: "Internal server error", message: error.message },
      { status: 500 }
    );
  }
}

// POST: Admin registration
export async function POST(req: Request) {
  try {
    const body = await req.json();
    const name = body?.name;
    const email = normalizeEmail(body?.email);
    const password = body?.password;
    const clientIP = getClientIP(req);
    const rateLimitKey = `register:${email || "unknown"}:${clientIP}`;
    const rateLimitResult = checkRateLimit(rateLimitKey, REGISTER_RATE_LIMIT_CONFIG);

    if (!rateLimitResult.success) {
      return NextResponse.json(
        {
          error: "Rate limit exceeded",
          message: `Too many registration attempts. Please try again after ${rateLimitResult.retryAfter} seconds.`,
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
    const adminCount = await Admin.countDocuments();

    // Bootstrap mode: allow creating the very first admin without authentication.
    if (adminCount > 0) {
      const authenticated = await isAuthenticatedAdmin();
      if (!authenticated) {
        return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
      }
    }

    // Check if admin already exists
    const existingAdmin = await Admin.findOne({ email });
    if (existingAdmin) {
      return NextResponse.json(
        { error: "Admin already exists" },
        { status: 400 }
      );
    }

    // Hash the password
    const hashedPassword = await bcrypt.hash(password, 10);

    // Create new admin
    const newAdmin = new Admin({ name, email, password: hashedPassword });
    await newAdmin.save();

    return NextResponse.json({ message: "Admin registered successfully" });
  } catch (error: any) {
    return NextResponse.json(
      { error: "Internal server error", message: error.message },
      { status: 500 }
    );
  }
}
