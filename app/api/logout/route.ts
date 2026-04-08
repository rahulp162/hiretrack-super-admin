import { NextResponse } from "next/server";
import { withoutAuthCookie } from "@/lib/auth";

// POST: clear admin auth cookie
export async function POST() {
  const res = NextResponse.json({ success: true });
  return withoutAuthCookie(res);
}
