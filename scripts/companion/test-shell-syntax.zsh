#!/bin/zsh
set -euo pipefail
root="${0:A:h}"
for script in "$root"/*.zsh; do
  zsh -n "$script"
done
print "companion shell syntax: PASS"
