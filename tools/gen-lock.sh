#!/usr/bin/env bash
set -euo pipefail
LOCK_IN=${1:-workflows/dna-seq/lockfile.yaml}
LOCK_OUT=${2:-workflows/dna-seq/lockfile.locked.yaml}

tmp=$(mktemp)
cp "$LOCK_IN" "$tmp"

# заполнить git_sha из переменной окружения (если передали)
if grep -q 'git_sha: <to-fill>' "$tmp" && [ -n "${GIT_SHA:-}" ]; then
  sed -i.bak "s#git_sha: <to-fill>#git_sha: ${GIT_SHA}#" "$tmp" || true
fi

# пройтись по images и подставить digest, если доступен docker
images=$(awk '/image: /{print $2}' "$tmp")
for img in $images; do
  docker pull "$img" >/dev/null 2>&1 || true
  dig=$(docker inspect --format='{{index .RepoDigests 0}}' "$img" 2>/dev/null | sed 's/.*@//') || true
  [ -z "$dig" ] && continue
  esc_img=$(printf '%s\n' "$img" | sed 's/[.[\*^$(){}?+|/]/\\&/g')
  awk -v IMG="$esc_img" -v DIG="$dig" '
    $0 ~ "image: "IMG {print; getline;
      if ($0 ~ /digest:/) { sub(/digest:.*/, "digest: "DIG); print; next }
      else { print "    digest: "DIG }
    }
    {print}
  ' "$tmp" > "$tmp.new" && mv "$tmp.new" "$tmp"
done

mv "$tmp" "$LOCK_OUT"
echo "Wrote $LOCK_OUT"
