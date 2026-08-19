[
  .runtimes[]
  | select(.isAvailable == true)
  | select((.identifier // "") | startswith("com.apple.CoreSimulator.SimRuntime.iOS-"))
  | select((.name // "") | startswith("iOS "))
  | select((((.version // "") | split("."))[0]) == "27")
]
| sort_by(.version | split(".") | map(tonumber))
| last
| .identifier // empty
