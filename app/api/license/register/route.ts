import { NextResponse } from "next/server";
import { connectToDatabase } from "@/lib/db";
import License from "@/app/models/license";
import Client from "@/app/models/client";
import History from "@/app/models/history";
import { licenseRegisterSchema } from "@/lib/validators";
import { generateLicenseKey } from "@/lib/license";
import crypto from 'crypto'; // 👈 1. Import crypto

// 👈 2. Add your Private Key securely
const LICENSE_PRIVATE_KEY = process.env.LICENSE_PRIVATE_KEY || `-----BEGIN PRIVATE KEY-----
[YOUR_PRIVATE_KEY_HERE]
-----END PRIVATE KEY-----`;

// POST: Register a new license for a client with machine code
export async function POST(req: Request) {
  try {
    await connectToDatabase();
    const body = await req.json();

    // Validate request body
    const validationResult = licenseRegisterSchema.safeParse(body);
    if (!validationResult.success) {
      return NextResponse.json(
        {
          error: "Invalid request data",
          details: validationResult.error.message,
        },
        { status: 400 }
      );
    }

    const { machineCode, version, email } = body;

    // Check if a license with the same email and machineCode already exists
    const existingLicense = await License.find({
      email: email,
      machineCode: machineCode,
      status: { $ne: "revoked" },
    });

    console.log("existingLicense", existingLicense);
    if (existingLicense && existingLicense.length > 0) {
      return NextResponse.json(
        {
          existingLicense: existingLicense,
          error: "A license for this email and machine code already exists.",
        },
        { status: 400 }
      );
    }

    // Check if a client exists with this email in the Client collection
    const existingClient = await Client.findOne({ email });
    if (!existingClient) {
      return NextResponse.json(
        {
          error:
            "No Client is registered with this email. Please the client through Super Admin.",
        },
        { status: 400 }
      );
    }

    // Generate a unique license key
    const licenseKey = generateLicenseKey(email, machineCode);

    // Create the license with machine code already bound
    const newLicense = new License({
      licenseKey,
      status: "active",
      machineCode,
      installedVersion: version,
      email,
    });

    await newLicense.save();

    // Log history for license creation
    await History.create({
      entityType: "license",
      entityId: newLicense._id.toString(),
      action: "license_created",
      description: `License registered for ${email} with machine code ${machineCode}`,
      newValue: "active",
      notes: `Initial version: ${version || "N/A"}`,
    });

    // 👇 3. NEW CRYPTOGRAPHIC LOGIC STARTS HERE 👇

    // Build the payload that the client will verify offline
    const payload = {
        licenseKey: newLicense.licenseKey,
        email: newLicense.email,
        machineCode: newLicense.machineCode
    };

    // Sign the payload
    const sign = crypto.createSign('SHA256');
    sign.update(JSON.stringify(payload));
    sign.end();
    console.log("LICENSE_PRIVATE_KEY", LICENSE_PRIVATE_KEY);
    const signature = sign.sign(LICENSE_PRIVATE_KEY, 'base64');

    console.log("signature", signature);

    // Return the payload and signature instead of just the license object
    return NextResponse.json({
      message: "License registered successfully",
      payload: payload,
      signature: signature
    });

  } catch (error: unknown) {
    console.error("Error registering license:", error);
    return NextResponse.json(
      { 
        error: "Internal server error", 
        message: error instanceof Error ? error.message : "Unknown error" 
      },
      { status: 500 }
    );
  }
}