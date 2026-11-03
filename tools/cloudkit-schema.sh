#!/bin/sh
# Deploy the Keys CloudKit schema from Development to Production with cktool.
#
# One-time setup: create a CloudKit management token in CloudKit Console (CloudKit Web Services),
# then:
#   xcrun cktool save-token --type management
#
# This script copies the current Development schema (Header, Item, KeysVault zone) into Production.
# It never deletes data.
set -eu
cd "$(dirname "$0")/.."

TEAM_ID="KZFR2T5L2A"
CONTAINER="iCloud.technology.asteria.keys"
SCHEMA="build/KeysSchema-development.ckdb"

mkdir -p build

if ! xcrun cktool export-schema --team-id "$TEAM_ID" --container-id "$CONTAINER" \
    --environment development --output-file "$SCHEMA" >/tmp/keys-schema-export.log 2>&1; then
    echo "Could not export the Development schema." >&2
    echo "Run: xcrun cktool save-token --type management" >&2
    echo "Then create a vault and one item in a Debug build so Header and Item exist." >&2
    cat /tmp/keys-schema-export.log >&2
    exit 1
fi

echo "Exported Development schema to $SCHEMA"

if ! xcrun cktool import-schema --team-id "$TEAM_ID" --container-id "$CONTAINER" \
    --environment production --file "$SCHEMA" --validate >/tmp/keys-schema-import.log 2>&1; then
    echo "Could not import the schema into Production." >&2
    cat /tmp/keys-schema-import.log >&2
    exit 1
fi

echo "Deployed the Keys schema to Production."
echo "Now install the same TestFlight (or Debug) build on both devices, then sync."
