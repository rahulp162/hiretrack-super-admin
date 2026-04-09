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
[PRIVATE_KEY]
-----END PRIVATE KEY-----`;

/// 2. 🚨 THE FIX: Force Node to parse any literal "\n" characters into actual line breaks
// const LICENSE_PRIVATE_KEY = `-----BEGIN PRIVATE KEY-----
// MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQD6r+WIQxWsiostYoh3UkNJy87kF3vnjqyOkC9Ueapgv4EQkFFqzpFwjGcX6Sx0Qa/eed17smGK0wHkcwIegiAODtWF33WR79gpf1L3wx3YiySoNaxphcR79Whqr+DI+YVTg5Q/m/NSCi1V3jMzDycbtmtjzqTlcau0LiYU+4VQA1u5T18UExrRqZxXA+VgNUwm3tEZ2QxwQX4BIu80eMkL+L9yD7YcifUQB1sqI2YWO3c8EPaC8Y4GrAadqY3xC4L1taedzhBxZDL9Rog+OQw1mPGrMV7L4omk/o1JoYQAVBkiKLXY76I9StSrRcSRfxqc32bEUAz04fY7Arkw/ICLAgMBAAECggEAGUaZRjhmsTYU21dxz/9s274fbEhhN1M02yOhigsXCS3gkFrPbWKfhRwQRve9LN70obdi2VZ+gZX4kl/1iOhGMsn/GxeRTfduBvJuBfTX3QixLP6gatFQeCPMdTlU2PQDo+HX6uPz+sPI7L1R0eZHY1gXaCxNMaSDk1ALNJa5oHv1x+M5h6tfZ9Sg+kyKWPfOqk1hMhvA2uIUOMjjzbAKT5iipFT96T+fEassnkGJnkVs2RL8W/OmcRmIySgqL4pjNr1UeaPk4pNGsT7++f30RCoEDHRdvPfL2rnXf2CS6k2DslHPqhgxr9pKasLBry+Q0ywxSXAQ/3OND8q5MbINmQKBgQD+KJypiWEue168hyHCjjAgSQ7SsdHumXeWDGIy0UFo4wsEuvbovlyIemL8E5VOe4/zDapC1HnywenjMEgCpL2t1DbZihQyyR0ZF2FIh8PUPZfEwvZhFctIYBKakC1I52CXzjx3KHPSoldBiW+EYcfdH2VX8fHCkRwFmDwIg2/tuQKBgQD8gNiR02rV2joHal9WcznHFoxZulmPjDM/aIQLFQ+CoOApFEkLu6dnVIowrzlwh9vuwPfdKDnmuL7956BlYzrdb6EsdBayaN7RJXayW181rax9hGv0Dt3XAyMEffTk7w33Rwp1LVQTol1tMF8OlGIkqQdJXl4rnxxpUQUKEKkiYwKBgHQ4/BLm+KK51cOeg8ilHsrUvcuJdzeFxFLATPNyD1g4YuSB3sDltAjQ9ozRI7ik9lmuCQrQgQeKtzql7HgQ/5AK+B4Yb04d+4lq0JjLRLi8hbd7dBFHVxM8o6U8gwjQjbI9pBbVT8mlZQNaJr3BvRSX8874m5ZepxLD38gA2uE5AoGBAMOsiagAQWN2GNAUU8tnwdeRlrQWID+Is1IpCWKZMIrXZr8O1Eh+ZI1Dy09NCuM0tXABJFPDT5OHiaKzs+2+BykAz9LmJ4ycjkdfk+tFubOcYfZm/02Dk9CCwslBXt1mj9kXuXfy55vLkEEEYjWnMaMdReNKeQmu5NKMka4qGRfnAoGANMobyr0jpXFgWWBrivQu4Mq8ukt3xRnwy+BhSKCOPrI/8eMlKkgCNtWhB9xYEwTjVWNcfUoHqy5oJzmClTfNVLRZSAUJEaJArlpYyDw3Key84GX8qpqYRQMUllOLbj2DAdbxgllZZLeLEAI6gU86IKeqbOVX68x3IqYmT+my0tU=
// -----END PRIVATE KEY-----`

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
    // const payload = {
    //     licenseKey: newLicense.licenseKey,
    //     email: newLicense.email,
    //     machineCode: newLicense.machineCode
    // };

    // Admin API POST Route
    const sign = crypto.createSign('SHA256');
    sign.update(machineCode); // ONLY the machine code string
    sign.end();
    const signature = sign.sign(LICENSE_PRIVATE_KEY, 'base64');

    return NextResponse.json({ signature: signature });

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