#!/bin/zsh
# Deploys edge functions from what's on main, never from a working copy:
# a clean main that matches origin, type-checked and tested first.
#
#   scripts/deploy-functions.sh                 # every function
#   scripts/deploy-functions.sh share parse     # just these
#
# Each deploy is recorded as a functions-<date>-<sha> tag, so what's live
# can always be traced to a commit.

set -euo pipefail
cd "$(dirname "$0")/.."

[[ $(git branch --show-current) == main ]] || { echo "Not on main." >&2; exit 1; }
[[ -z $(git status --porcelain) ]] || { echo "Uncommitted changes; commit them first." >&2; exit 1; }
git fetch -q origin main
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || { echo "main and origin/main differ; pull or push first." >&2; exit 1; }

deno check --frozen supabase/functions/*/index.ts supabase/functions/_shared/*.ts
deno test --frozen --allow-env --allow-read --quiet supabase/functions/_shared/

supabase functions deploy "$@"

tag="functions-$(date -u +%Y%m%d-%H%M)-$(git rev-parse --short HEAD)"
git tag "$tag"
git push -q origin "$tag"
echo "Deployed from $(git rev-parse --short HEAD), tagged $tag"
