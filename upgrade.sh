#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Defaults / Config
# -----------------------------
ORG_NAME="https://github.com/mandeep4u"
BRANCH_NAME="upgrade-dependency-versions"

CREATE_PR=false
UPDATE_PATCH_VERSION=false
STRICT_TAGS=false

SOURCE_REPO=""  # parent repo spec for auto tag resolution (repo|org/repo|url)

declare -a TAG_NAMES=()
declare -a TAG_VERSIONS=()

# -----------------------------
# Helpers
# -----------------------------
usage() {
  cat <<'EOF'
Usage:
  ./upgrade.sh [--org <https://github.com/org>] \
               [--from-repo <parentRepoSpec>] \
               [--tag <TAG_NAME> [TAG_VERSION]]... \
               [--patch] [--strict-tags] [--pr]

Where:
  parentRepoSpec can be:
    - repoName
    - org/repoName
    - https://github.com/org/repoName
    - https://github.com/org/repoName.git

Notes:
  - If TAG_VERSION is omitted, script reads <TAG_NAME> value from parent repo pom.xml (requires --from-repo).
  - Target repos are read from repos.txt (one repo name per line; lines starting with # are ignored).
  - Missing tag in child repo is NEVER added; it is skipped with WARN (or ERROR with --strict-tags).
  - --patch bumps ONLY the project version (the <version> right after the first <artifactId>) and does NOT touch dependency versions.
EOF
}

die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN: $*" >&2; }

# Portable sed -i for macOS/Linux/GitBash
sed_inplace() {
  local expr="$1"
  local file="$2"
  if sed --version >/dev/null 2>&1; then
    sed -i "$expr" "$file"
  else
    sed -i '' "$expr" "$file" 2>/dev/null || sed -i "$expr" "$file"
  fi
}

strip_snapshot() { echo "$1" | sed 's/-SNAPSHOT$//'; }

# Normalize repo spec to clone URL
normalize_repo_to_url() {
  local spec="$1"

  # URL already?
  if [[ "$spec" =~ ^https?:// ]]; then
    [[ "$spec" =~ \.git$ ]] && echo "$spec" || echo "${spec}.git"
    return
  fi

  # org/repo
  if [[ "$spec" == */* ]]; then
    echo "https://github.com/${spec}.git"
    return
  fi

  # repo only -> ORG_NAME
  echo "${ORG_NAME%/}/${spec}.git"
}

# -----------------------------
# XML helpers (sed/awk only - no formatting changes)
# -----------------------------
# Gets first occurrence of <tag>VALUE</tag> on a single line.
get_xml_tag_value() {
  local tag="$1"
  local file="$2"
  awk -v t="$tag" '
    $0 ~ "<"t">" {
      if (match($0, "<"t">[^<]*</"t">")) {
        s = substr($0, RSTART, RLENGTH)
        sub("^<"t">", "", s)
        sub("</"t">$", "", s)
        print s
        exit
      }
    }
  ' "$file"
}

# Replace occurrences of <tag>...</tag> with new value (single-line tags).
replace_xml_tag_value() {
  local tag="$1"
  local new="$2"
  local file="$3"
  sed_inplace "s|<${tag}>[^<]*</${tag}>|<${tag}>${new}</${tag}>|g" "$file"
}

# Bump ONLY project version: first <version> after first <artifactId> in file
# Matches your pom layout:
# <groupId>..</groupId>
# <artifactId>..</artifactId>
# <version>1.0.4-SNAPSHOT</version>
bump_project_version_only() {
  local file="$1"

  # Find the line number of the FIRST <version> after the FIRST <artifactId>
  local ver_line
  ver_line="$(awk '
    BEGIN { seenAid=0 }
    /<artifactId>/ { seenAid=1 }
    seenAid && /<version>[[:space:]]*[^<]+[[:space:]]*<\/version>/ {
      print NR
      exit
    }
  ' "$file" || true)"

  if [ -z "${ver_line:-}" ]; then
    warn "Could not locate project <version> after <artifactId> (skipping patch bump)."
    return 0
  fi

  # Extract current version from that exact line
  local current
  current="$(awk -v n="$ver_line" 'NR==n {
      s=$0
      sub(/.*<version>[[:space:]]*/, "", s)
      sub(/[[:space:]]*<\/version>.*/, "", s)
      print s
    }' "$file" || true)"

  if [ -z "${current:-}" ]; then
    warn "Found version line ($ver_line) but could not parse version value (skipping)."
    return 0
  fi

  local base major minor patch
  base="$(strip_snapshot "$current")"
  IFS='.' read -r major minor patch <<< "$base"

  if [ -z "${major:-}" ] || [ -z "${minor:-}" ] || [ -z "${patch:-}" ]; then
    warn "Project version '$current' not in MAJOR.MINOR.PATCH format (skipping patch bump)."
    return 0
  fi

  local new_version="${major}.${minor}.$((patch+1))-SNAPSHOT"
  echo "Bumping project <version> on line $ver_line: $current -> $new_version"

  # Replace ONLY that one line (portable across GNU/BSD sed)
  local new_line="<version>${new_version}</version>"
  sed_inplace "${ver_line}s|<version>[^<]*</version>|${new_line}|" "$file"

  echo "$new_version"
}

# -----------------------------
# Git helpers
# -----------------------------
get_default_branch() {
  git remote show origin 2>/dev/null | awk '/HEAD branch/ {print $NF}' | head -n 1
}

ensure_prereqs() {
  if [ "$CREATE_PR" = true ]; then
    command -v gh >/dev/null 2>&1 || die "gh CLI not found but --pr requested."
    gh auth status >/dev/null 2>&1 || die "gh CLI not authenticated. Run: gh auth login"
  fi
}

# Resolve missing tag versions from parent repo
resolve_missing_tag_versions_from_parent() {
  local needs_parent=false
  for i in "${!TAG_NAMES[@]}"; do
    if [ -z "${TAG_VERSIONS[$i]}" ]; then
      needs_parent=true
      break
    fi
  done

  if [ "$needs_parent" = true ] && [ -z "${SOURCE_REPO:-}" ]; then
    die "You used --tag <NAME> without a version. Provide parent repo using --from-repo <repo|org/repo|url>."
  fi

  [ "$needs_parent" = false ] && return 0

  local parent_url
  parent_url="$(normalize_repo_to_url "$SOURCE_REPO")"

  echo "Auto-resolving missing tag versions from parent repo: $SOURCE_REPO"
  echo "Parent clone URL: $parent_url"

  local tmp_dir
  tmp_dir="$(mktemp -d ".tmp_parent_repo.XXXXXX")"
  trap 'rm -rf "$tmp_dir" >/dev/null 2>&1 || true' RETURN

  git clone --depth 1 "$parent_url" "$tmp_dir" >/dev/null

  [ -f "$tmp_dir/pom.xml" ] || die "Parent repo pom.xml not found at repo root."

  for i in "${!TAG_NAMES[@]}"; do
    if [ -z "${TAG_VERSIONS[$i]}" ]; then
      local tag="${TAG_NAMES[$i]}"
      local val
      val="$(get_xml_tag_value "$tag" "$tmp_dir/pom.xml" || true)"
      [ -n "${val:-}" ] || die "Tag <$tag> not found in parent repo pom.xml."
      TAG_VERSIONS[$i]="$val"
      echo "Resolved <$tag> = $val"
    fi
  done
}

# -----------------------------
# Parse args
# -----------------------------
if [ $# -eq 0 ]; then usage; exit 1; fi

while [ $# -gt 0 ]; do
  case "$1" in
    --org)
      [ $# -lt 2 ] && die "--org requires a value"
      ORG_NAME="$2"
      shift 2
      ;;
    --from-repo|--parent-repo)
      [ $# -lt 2 ] && die "--from-repo requires a value"
      SOURCE_REPO="$2"
      echo "Parent repo: $SOURCE_REPO"
      shift 2
      ;;
    --tag)
      [ $# -lt 2 ] && die "--tag requires <TAG_NAME> [TAG_VERSION]"
      TAG_NAMES+=("$2")

      if [ $# -ge 3 ] && [[ "${3:-}" != --* ]]; then
        TAG_VERSIONS+=("$3")
        echo "TAG: $2 -> $3"
        shift 3
      else
        TAG_VERSIONS+=("")
        echo "TAG: $2 -> (auto from parent repo)"
        shift 2
      fi
      ;;
    --patch)
      UPDATE_PATCH_VERSION=true
      shift
      ;;
    --strict-tags)
      STRICT_TAGS=true
      shift
      ;;
    --pr)
      CREATE_PR=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

[ -f repos.txt ] || die "repos.txt not found in current directory."

echo "-----------------------------------------------"
echo "Org base: ${ORG_NAME%/}"
echo "Branch: $BRANCH_NAME"
echo "Create PR: $CREATE_PR"
echo "Patch bump: $UPDATE_PATCH_VERSION"
echo "Strict tags: $STRICT_TAGS"
echo "Parent repo: ${SOURCE_REPO:-<none>}"
echo "Tags: ${#TAG_NAMES[@]}"
echo "XML edit mode: sed-only (no formatting changes)"
echo "-----------------------------------------------"

ensure_prereqs

# Resolve tag values from parent once (only if any missing)
if [ "${#TAG_NAMES[@]}" -gt 0 ]; then
  resolve_missing_tag_versions_from_parent
fi

echo "Starting upgrade process..."

# -----------------------------
# Process child repos
# -----------------------------
while IFS= read -r repo || [ -n "$repo" ]; do
  repo="$(echo "$repo" | tr -d '\r' | xargs || true)"
  [ -z "$repo" ] && continue
  [[ "$repo" =~ ^# ]] && continue

  COMMIT_MESSAGE="Upgrade:"
  echo "==============================================="
  echo "** Processing repo: $repo"
  echo "==============================================="

  rm -rf "$repo" >/dev/null 2>&1 || true

  child_url="${ORG_NAME%/}/${repo}.git"
  echo "** Cloning: $child_url"
  git clone --depth 1 "$child_url" "$repo"

  pushd "$repo" >/dev/null
  trap 'popd >/dev/null 2>&1 || true' RETURN

  default_branch="$(get_default_branch || true)"
  [ -n "${default_branch:-}" ] || default_branch="main"
  echo "** Default branch detected: $default_branch"

  git checkout "$default_branch"
  git pull origin "$default_branch"

  # Create/reset working branch
  git checkout -B "$BRANCH_NAME"

  if [ ! -f pom.xml ]; then
    warn "No pom.xml in repo root for $repo. Skipping."
    popd >/dev/null
    trap - RETURN
    continue
  fi

  # ---- Apply tag updates ----
  if [ "${#TAG_NAMES[@]}" -gt 0 ]; then
    for i in "${!TAG_NAMES[@]}"; do
      tname="${TAG_NAMES[$i]}"
      tver="${TAG_VERSIONS[$i]}"

      current="$(get_xml_tag_value "$tname" pom.xml || true)"
      if [ -z "${current:-}" ]; then
        msg="Tag <$tname> does not exist in child repo '$repo' (skipping update)."
        if [ "$STRICT_TAGS" = true ]; then
          die "$msg"
        else
          warn "$msg"
          continue
        fi
      fi

      if [ "$current" = "$tver" ]; then
        echo "No change for <$tname> ($current)."
        continue
      fi

      echo "Updating <$tname>: $current -> $tver"
      replace_xml_tag_value "$tname" "$tver" pom.xml
      COMMIT_MESSAGE+=" ${tname}=${tver};"
    done
  fi

  # ---- Patch version bump (project version ONLY) ----
  if [ "$UPDATE_PATCH_VERSION" = true ]; then
    if [ "$repo" = "linking-consumerheader-logviewer" ]; then
      # revision bump (single-line expected)
      CURRENT_REV="$(get_xml_tag_value "revision" pom.xml || true)"
      if [ -n "${CURRENT_REV:-}" ]; then
        base="$(strip_snapshot "$CURRENT_REV")"
        IFS='.' read -r MAJOR MINOR PATCH <<< "$base"
        if [ -n "${MAJOR:-}" ] && [ -n "${MINOR:-}" ] && [ -n "${PATCH:-}" ]; then
          NEW_REV="${MAJOR}.${MINOR}.$((PATCH+1))-SNAPSHOT"
          echo "Bumping <revision>: $CURRENT_REV -> $NEW_REV"
          replace_xml_tag_value "revision" "$NEW_REV" pom.xml
          COMMIT_MESSAGE+=" patch=${NEW_REV};"
        else
          warn "Revision '$CURRENT_REV' not in MAJOR.MINOR.PATCH format (skipping)."
        fi
      else
        warn "No <revision> found (skipping)."
      fi
    else
      bumped="$(bump_project_version_only pom.xml || true)"
      [ -n "${bumped:-}" ] && COMMIT_MESSAGE+=" patch=${bumped};"
    fi
  fi

  # ---- Commit / Push / PR ----
  if git diff --quiet; then
    echo "No changes detected in $repo. Skipping commit & push."
    popd >/dev/null
    trap - RETURN
    rm -rf "$repo" >/dev/null 2>&1 || true
    continue
  fi

  echo "Diff (pom.xml):"
  git diff -- pom.xml || true

  git add pom.xml
  git commit -m "$COMMIT_MESSAGE"

  git push origin "$BRANCH_NAME"
  echo "** Pushed branch $BRANCH_NAME for $repo **"

  if [ "$CREATE_PR" = true ]; then
    echo "** Creating PR for $repo **"
    gh pr create \
      --title "Upgrade dependency versions" \
      --body "$COMMIT_MESSAGE" \
      --head "$BRANCH_NAME" \
      --base "$default_branch"
    echo "** PR created for $repo **"
  else
    echo "** PR creation skipped for $repo **"
  fi

  popd >/dev/null
  trap - RETURN
  rm -rf "$repo" >/dev/null 2>&1 || true

done < repos.txt

echo "Upgrade process completed."
