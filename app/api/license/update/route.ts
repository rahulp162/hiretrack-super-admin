import { NextResponse } from "next/server";
import { connectToDatabase } from "@/lib/db";
import License from "@/app/models/license";
import History from "@/app/models/history";
import Client from "@/app/models/client";
import crypto from 'crypto';

// 🚨 Ensure your formatting handles line breaks correctly from Vercel .env
const LICENSE_PRIVATE_KEY = process.env.LICENSE_PRIVATE_KEY || `-----BEGIN PRIVATE KEY-----
[YOUR_PRIVATE_KEY_HERE]
-----END PRIVATE KEY-----`;

// PATCH: Update license details (Hardware lock, version, etc)
export async function PATCH(req: Request) {
  try {
    await connectToDatabase();
    const body = await req.json();

    // 1. Extract fields from the request (licenseKey is completely gone!)
    const { email, machineCode, status, installedVersion, expiryDate } = body;

    if (!email) {
      return NextResponse.json(
        { error: "Email is required to update a license" },
        { status: 400 }
      );
    }

    // 2. Verify the Client is still active
    const existingClient = await Client.findOne({ email: email });
    if (!existingClient || existingClient.status === "deactivated") {
      return NextResponse.json(
        { error: "No active Client is registered with this email." },
        { status: 400 }
      );
    }

    // 3. Find the active license for this email
    const existingLicense = await License.findOne({
      email: email,
      status: { $ne: "revoked" },
    });

    if (!existingLicense) {
      return NextResponse.json(
        { error: "No active license found for this email." },
        { status: 404 }
      );
    }

    // 4. Update fields if they were provided in the request
    let changesMade = false;

    if (machineCode && existingLicense.machineCode !== machineCode) {
      const oldMachineCode = existingLicense.machineCode;
      existingLicense.machineCode = machineCode;
      changesMade = true;

      await History.create({
        entityType: "license",
        entityId: existingLicense._id.toString(),
        action: "machine_code_updated",
        description: `Hardware lock updated for ${email} to ${machineCode}`,
        oldValue: oldMachineCode,
        newValue: machineCode,
      });
    }

    if (status && existingLicense.status !== status) {
      const oldStatus = existingLicense.status;
      existingLicense.status = status;
      changesMade = true;

      await History.create({
        entityType: "license",
        entityId: existingLicense._id.toString(),
        action: "status_changed",
        description: `License status changed from ${oldStatus} to ${status}`,
        oldValue: oldStatus,
        newValue: status,
      });
    }

    if (installedVersion && existingLicense.installedVersion !== installedVersion) {
      const oldVersion = existingLicense.installedVersion;
      existingLicense.installedVersion = installedVersion;
      changesMade = true;

      await History.create({
        entityType: "license",
        entityId: existingLicense._id.toString(),
        action: "version_updated",
        description: `Installed version updated from ${oldVersion || "N/A"} to ${installedVersion}`,
        oldValue: oldVersion || null,
        newValue: installedVersion,
      });
    }

    if (expiryDate !== undefined) {
      const parsedDate = expiryDate === "" ? null : new Date(expiryDate);
      existingLicense.expiryDate = parsedDate;
      changesMade = true;
    }

    // Save the updates to MongoDB@
    if (changesMade) {
      await existingLicense.save();
    }

    // 👇 5. NEW CRYPTOGRAPHIC LOGIC 👇
    // Generate the Ultimate Minimal Signature using ONLY the authorized machine code
    const sign = crypto.createSign('SHA256');
    sign.update(existingLicense.machineCode); 
    sign.end();
    
    const newSignature = sign.sign(LICENSE_PRIVATE_KEY, 'base64');

    // Return STRICTLY the signature so the bash script can save it to license.json
    return NextResponse.json({
      signature: newSignature
    });

  } catch (error: unknown) {
    console.error("Error updating license:", error);
    return NextResponse.json(
      { 
        error: "Internal server error", 
        message: error instanceof Error ? error.message : "Unknown error" 
      },
      { status: 500 }
    );
  }
}