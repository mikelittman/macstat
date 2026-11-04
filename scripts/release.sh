#!/bin/bash
# Publish the next patch release from the current main commit.
# Tags are the version source. v0.1.0 is the first release, then v0.1.1, and so on.
# A commit already tagged is reused so a re-run does not mint another version.

set -euo pipefail

if [ -z "${GITHUB_ACTIONS:-}" ]; then
  echo "scripts/release.sh publishes a GitHub release and runs from Actions." >&2
  exit 1
fi

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"

git fetch origin --tags --force

tags=$(git tag -l 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname)
latest=${tags%%$'\n'*}

exact=$(git describe --exact-match --tags --match 'v[0-9]*.[0-9]*.[0-9]*' HEAD 2>/dev/null || true)
if [ -n "$exact" ]; then
  version=${exact#v}
else
  if [ -z "$latest" ]; then
    version=0.1.0
  else
    IFS=. read -r major minor patch <<< "${latest#v}"
    patch=${patch%%[^0-9]*}
    version="${major}.${minor}.$((patch + 1))"
  fi
fi

tag="v${version}"
asset="macstat-${version}-macos.tar.gz"
echo "Publishing ${tag}"

swift build -c release --arch arm64 --arch x86_64
bin="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/macstat"
codesign --sign - --force "$bin"
lipo "$bin" -verify_arch arm64 x86_64

mkdir -p dist
tar -C "$(dirname "$bin")" -czf "dist/${asset}" "$(basename "$bin")"
shasum -a 256 "dist/${asset}" | tee dist/checksums.txt
sha=$(awk '{print $1}' dist/checksums.txt)

if [ -n "$exact" ] || [ -z "$latest" ]; then
  notes="Release ${tag}."
else
  notes=$(git log "${latest}..HEAD" --pretty=format:'- %s' --no-merges)
fi
if [ -z "$notes" ]; then
  notes="Release ${tag}."
fi

if ! git rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
  git tag -a "$tag" -m "macstat ${tag}"
  git push origin "$tag"
fi

if gh release view "$tag" >/dev/null 2>&1; then
  gh release upload "$tag" "dist/${asset}" dist/checksums.txt --clobber
else
  gh release create "$tag" "dist/${asset}" dist/checksums.txt --title "$tag" --notes "$notes"
fi

cat > Formula/macstat.rb << EOF
# Rewritten by scripts/release.sh when a version is published.
class Macstat < Formula
  desc "Full-screen terminal monitor for Mac system stats"
  homepage "https://github.com/mikelittman/macstat"
  url "https://github.com/mikelittman/macstat/releases/download/${tag}/macstat-${version}-macos.tar.gz"
  sha256 "${sha}"
  license "MIT"
  version "${version}"

  livecheck do
    url :homepage
    strategy :github_latest
  end

  depends_on macos: :sonoma

  def install
    bin.install "macstat"
  end

  test do
    assert_match "macstat", shell_output("#{bin}/macstat --help")
  end
end
EOF

if git diff --quiet -- Formula/macstat.rb; then
  echo "Formula already matches ${tag}"
  exit 0
fi

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add Formula/macstat.rb
git commit -m "chore: release ${tag}"
git push origin HEAD:main
