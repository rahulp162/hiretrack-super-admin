#!/bin/bash
# Package artifacts for deployment. Converts .env.local → .env and ships .env only.

set -e

ARTIFACTS_FILE="artifacts.tar"

echo "📦 Packaging artifacts..."
echo ""

# Check if .next exists
if [ ! -d ".next" ]; then
    echo "❌ Error: .next directory not found. Please run 'npm run build' first."
    exit 1
fi

# Check if package.json exists
if [ ! -f "package.json" ]; then
    echo "❌ Error: package.json not found."
    exit 1
fi

# Convert .env.local → .env for the artifact (single .env file)
if [ -f ".env.production" ]; then
    cp .env.production .env
else
    echo "⚠️  Warning: .env.production not found; no .env will be included."
fi

# Remove old artifacts file if exists
if [ -f "$ARTIFACTS_FILE" ]; then
    echo "🗑️  Removing old $ARTIFACTS_FILE..."
    rm -f "$ARTIFACTS_FILE"
fi

# Strip macOS extended attributes so Linux extraction has no warnings
if command -v xattr >/dev/null 2>&1; then
    echo "🧹 Stripping macOS extended attributes..."
    xattr -cr .next 2>/dev/null || true
    for f in package.json package-lock.json .env; do
        [ -e "$f" ] && xattr -c "$f" 2>/dev/null || true
    done
fi

# Create tarball with .env only
echo "📦 Creating $ARTIFACTS_FILE..."
if tar --version | grep -q "GNU tar"; then
    tar --no-xattrs -czf "$ARTIFACTS_FILE" \
        .next \
        package.json \
        package-lock.json \
        .env 2>/dev/null || tar --no-xattrs -czf "$ARTIFACTS_FILE" .next package.json package-lock.json
else
    COPYFILE_DISABLE=1 tar --disable-copyfile -czf "$ARTIFACTS_FILE" \
        .next \
        package.json \
        package-lock.json \
        .env 2>/dev/null || COPYFILE_DISABLE=1 tar --disable-copyfile -czf "$ARTIFACTS_FILE" .next package.json package-lock.json
fi

# Remove temporary .env (do not leave in repo)
[ -f ".env" ] && rm -f .env

if [ -f "$ARTIFACTS_FILE" ]; then
    echo "✅ Created $ARTIFACTS_FILE ($(du -h "$ARTIFACTS_FILE" | cut -f1))"
    echo "   .next/ package.json package-lock.json .env"
else
    echo "❌ Failed to create $ARTIFACTS_FILE"
    exit 1
fi
