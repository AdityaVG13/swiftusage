#!/bin/zsh
# Refreshes the prices bundled with the app (Sources/UsageCore/Pricing/BundledPrices.swift) from LiteLLM's
# public price list and OpenUsage's pricing supplement. The app also refetches LiteLLM's list once a day.
set -euo pipefail

cd "$(dirname "$0")/.."
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

curl -fsSL -o "$WORK/litellm.json" https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json
curl -fsSL -o "$WORK/supplement.json" https://raw.githubusercontent.com/robinebers/openusage/main/Sources/OpenUsage/Resources/pricing_supplement.json

swift build --product swiftusage
"$(swift build --show-bin-path)/swiftusage" --price-table "$WORK/litellm.json" "$WORK/supplement.json" > "$WORK/BundledPrices.swift"
mv "$WORK/BundledPrices.swift" Sources/UsageCore/Pricing/BundledPrices.swift
echo "Updated Sources/UsageCore/Pricing/BundledPrices.swift"
