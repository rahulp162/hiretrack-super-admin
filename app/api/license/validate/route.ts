import { NextRequest, NextResponse } from "next/server";
import { connectToDatabase } from "@/lib/db";
import { validateLicense } from "@/lib/license";
import { licenseValidateSchema } from "@/lib/validators";
import { checkRateLimit } from "@/lib/ratelimit";
import { isBetaMode } from "@/app/configs/github.config";

// Rate limit configuration
const RATE_LIMIT_CONFIG = {
  maxRequests: 5, // Maximum 5 requests
  windowMs: 60 * 1000, // Per 60 seconds (1 minute)
};

// POST: Validate a license
export async function POST(req: NextRequest) {
  try {
    // Get client IP address from request headers
    const forwardedFor = req.headers.get("x-forwarded-for");
    const realIP = req.headers.get("x-real-ip");
    const clientIP = forwardedFor?.split(",")[0].trim() || realIP || req.headers.get("cf-connecting-ip") || "unknown";
    
    const { searchParams } = new URL(req.url);
    const beta = isBetaMode(searchParams);
    // Check rate limit
    const rateLimitResult = checkRateLimit(clientIP, RATE_LIMIT_CONFIG);

    if (!rateLimitResult.success) {
      return NextResponse.json(
        {
          error: "Rate limit exceeded",
          message: `Too many requests. Please try again after ${rateLimitResult.retryAfter} seconds.`,
          retryAfter: rateLimitResult.retryAfter,
          valid: false,
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
    const body = await req.json();

    // Validate request body
    const validationResult = licenseValidateSchema.safeParse(body);
    console.log("validationResult", validationResult);
    if (!validationResult.success) {
      return NextResponse.json(
        {
          error: "Invalid request data",
          details: validationResult.error.message,
        },
        { status: 400 }
      );
    }

    const { licenseKey, machineCode, installedVersion } = body;

    // Validate the license
    const validationResult2 = await validateLicense(
      licenseKey,
      machineCode,
      installedVersion,
      beta || false
    );
    if (!validationResult2.valid) {
      return NextResponse.json(
        {
          valid: false,
          message: validationResult2.message,
        },
        { status: 400 }
      );
    }

    return NextResponse.json(
      {
        valid: true,
        asset: validationResult2.asset,
        licenseData: validationResult2.licenseData,
      },
      {
        headers: {
          "X-RateLimit-Limit": rateLimitResult.limit.toString(),
          "X-RateLimit-Remaining": rateLimitResult.remaining.toString(),
          "X-RateLimit-Reset": new Date(rateLimitResult.reset).toISOString(),
        },
      }
    );
  } catch (error: unknown) {
    console.error("Error validating license:", error);
    return NextResponse.json(
      { 
        error: "Internal server error", 
        message: error instanceof Error ? error.message : "Unknown error" 
      },
      { status: 500 }
    );
  }
}
