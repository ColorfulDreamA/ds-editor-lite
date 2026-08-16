#!/usr/bin/env bash
set -euo pipefail

# Script to fix dylib paths and signing for the macOS app bundle after
# macdeployqt has deployed Qt and vcpkg libraries.
#
# Responsibilities:
#   1. Deploy Qt translations (qtbase_zh_CN.qm / qt_zh_CN.qm) into the bundle.
#   2. Deploy ffmpeg dependency dylibs that the vcpkg ffmpeg-builds port does
#      not install into vcpkg/installed, and rewrite their loader paths.
#   3. Deploy vcpkg dylibs that are only referenced by custom PlugIns dylibs.
#   4. Replace hardcoded Qt framework paths (e.g. /opt/homebrew/.../QtCore) with @rpath.
#
# Code signing is performed by CMake as the final POST_BUILD step.

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <bundle_dir> [verbose] [vcpkg_installed_dir] [qt6_dir] [vcpkg_target_triplet]"
    echo "  bundle_dir:          Path to .app bundle (e.g., /path/to/App.app)"
    echo "  verbose:             Set to 1 for verbose output (optional)"
    echo "  vcpkg_installed_dir: vcpkg installed directory (optional)"
    echo "  qt6_dir:             Qt6 CMake package directory (optional)"
    echo "  vcpkg_target_triplet: vcpkg target triplet (optional)"
    exit 1
fi

BUNDLE_DIR="$1"
VERBOSE="${2:-0}"
VCPKG_INSTALLED_DIR="${3:-}"
QT6_DIR="${4:-}"
VCPKG_TARGET_TRIPLET="${5:-}"

if [[ ! -d "$BUNDLE_DIR" ]]; then
    echo "Error: Bundle directory not found: $BUNDLE_DIR" >&2
    exit 1
fi

# Extract .app name if full path is provided
if [[ "$BUNDLE_DIR" == *.app ]]; then
    APP_NAME=$(basename "$BUNDLE_DIR" .app)
    FRAMEWORKS_DIR="$BUNDLE_DIR/Contents/Frameworks"
else
    echo "Error: Bundle directory must be a .app bundle" >&2
    exit 1
fi

if [[ ! -d "$FRAMEWORKS_DIR" ]]; then
    echo "Warning: Frameworks directory not found: $FRAMEWORKS_DIR" >&2
    exit 0
fi

log() {
    if [[ "$VERBOSE" == "1" ]]; then
        echo "$@"
    fi
}

# -----------------------------------------------
# 1. Deploy Qt translations
# -----------------------------------------------
deploy_qt_translations() {
    if [[ -z "$QT6_DIR" ]]; then
        log "qt6_dir not provided; skipping Qt translation deployment."
        return 0
    fi

    # Qt6_DIR is normally <qt_prefix>/macos/lib/cmake/Qt6; the Qt translations
    # live at <qt_prefix>/macos/translations.
    local qt_translations_dir="$QT6_DIR/../../../translations"
    if [[ ! -d "$qt_translations_dir" ]]; then
        echo "Warning: Qt translations directory not found: $qt_translations_dir" >&2
        return 0
    fi

    local dest="$BUNDLE_DIR/Contents/translations"
    mkdir -p "$dest"

    for name in qtbase_zh_CN.qm qt_zh_CN.qm; do
        if [[ -f "$qt_translations_dir/$name" ]]; then
            cp "$qt_translations_dir/$name" "$dest/$name"
            log "Deployed Qt translation: $name"
        else
            echo "Warning: Qt translation not found: $qt_translations_dir/$name" >&2
        fi
    done
}

# -----------------------------------------------
# 2. Fix ffmpeg dylibs deployed by macdeployqt
# -----------------------------------------------
fix_ffmpeg_dylibs() {
    local ffmpeg_src_lib=""

    if [[ -n "$VCPKG_INSTALLED_DIR" ]]; then
        local vcpkg_root=""
        local candidate
        # vcpkg_installed_dir may be either <vcpkg_root>/installed or
        # <vcpkg_root>/installed/<triplet>, depending on how vcpkg was invoked.
        for candidate in "$VCPKG_INSTALLED_DIR/.." "$VCPKG_INSTALLED_DIR/../.."; do
            if [[ -d "$candidate/buildtrees/ffmpeg-builds/src" ]]; then
                vcpkg_root="$(cd "$candidate" 2>/dev/null && pwd || true)"
                break
            fi
        done
        if [[ -n "$vcpkg_root" ]]; then
            # Pick the first extracted ffmpeg-builds source lib directory.
            ffmpeg_src_lib="$(find "$vcpkg_root/buildtrees/ffmpeg-builds/src" \
                -maxdepth 2 -type d -name lib 2>/dev/null | head -1 || true)"
        fi
    fi

    if [[ -z "$ffmpeg_src_lib" || ! -d "$ffmpeg_src_lib" ]]; then
        log "ffmpeg-builds source lib directory not found; skipping ffmpeg dylib fix."
        return 0
    fi

    # Keep copying missing dependency dylibs until no new file is added
    # (libavcodec references @loader_path/ffmpeg-builds/libX, and libX may
    # itself reference /tmp/vendor/lib/libY which is also missing).
    local passes=0
    local added=1
    while [[ "$added" == "1" && "$passes" -lt 10 ]]; do
        added=0
        for dylib in "$FRAMEWORKS_DIR"/*.dylib; do
            [[ -f "$dylib" ]] || continue
            while IFS= read -r dep; do
                [[ -z "$dep" ]] && continue
                case "$dep" in
                    @loader_path/ffmpeg-builds/*|/tmp/vendor/lib/*)
                        local base
                        base="$(basename "$dep")"
                        if [[ ! -f "$FRAMEWORKS_DIR/$base" && -f "$ffmpeg_src_lib/$base" ]]; then
                            cp "$ffmpeg_src_lib/$base" "$FRAMEWORKS_DIR/$base"
                            log "Deployed missing ffmpeg dylib: $base"
                            added=1
                        fi
                        ;;
                esac
            done < <(otool -L "$dylib" 2>/dev/null | tail -n +2 | awk '{print $1}' || true)
        done
        passes=$((passes + 1))
    done

    # Rewrite every non-system dylib so it references its neighbours by
    # @loader_path instead of the vcpkg build machine's absolute paths or the
    # ffmpeg-builds subdirectory layout.
    for dylib in "$FRAMEWORKS_DIR"/*.dylib; do
        [[ -f "$dylib" ]] || continue

        local old_id
        old_id="$(otool -D "$dylib" 2>/dev/null | tail -1 || true)"
        if [[ "$old_id" == /tmp/vendor/lib/* ]]; then
            install_name_tool -id "@loader_path/$(basename "$old_id")" "$dylib"
            log "Fixed id for $(basename "$dylib"): $old_id"
        fi

        while IFS= read -r dep; do
            [[ -z "$dep" ]] && continue
            case "$dep" in
                @loader_path/ffmpeg-builds/*|/tmp/vendor/lib/*)
                    local newdep
                    newdep="@loader_path/$(basename "$dep")"
                    if [[ "$dep" != "$newdep" ]]; then
                        install_name_tool -change "$dep" "$newdep" "$dylib"
                        log "Fixed dep in $(basename "$dylib"): $dep -> $newdep"
                    fi
                    ;;
            esac
        done < <(otool -L "$dylib" 2>/dev/null | tail -n +2 | awk '{print $1}' || true)
    done
}

# -----------------------------------------------
# 3. Deploy missing vcpkg dylibs required by PlugIns
# -----------------------------------------------
deploy_missing_vcpkg_dylibs() {
    local vcpkg_lib=""

    if [[ -n "$VCPKG_INSTALLED_DIR" ]]; then
        if [[ -n "$VCPKG_TARGET_TRIPLET" && -d "$VCPKG_INSTALLED_DIR/$VCPKG_TARGET_TRIPLET/lib" ]]; then
            vcpkg_lib="$VCPKG_INSTALLED_DIR/$VCPKG_TARGET_TRIPLET/lib"
        elif [[ -d "$VCPKG_INSTALLED_DIR/lib" ]]; then
            vcpkg_lib="$VCPKG_INSTALLED_DIR/lib"
        fi
    fi

    if [[ -z "$vcpkg_lib" || ! -d "$vcpkg_lib" ]]; then
        log "vcpkg lib directory not found; skipping missing dylib deployment."
        return 0
    fi

    local plugins_dir="$BUNDLE_DIR/Contents/PlugIns"
    local added=1
    local passes=0

    # macdeployqt does not deploy vcpkg dylibs that are only referenced by
    # custom PlugIns dylibs. Scan every dylib in the bundle and copy any
    # missing @rpath dependency from the vcpkg lib directory, then repeat so
    # transitive dependencies are covered too.
    while [[ "$added" == "1" && "$passes" -lt 20 ]]; do
        added=0
        while IFS= read -r dylib; do
            [[ -f "$dylib" ]] || continue
            while IFS= read -r dep; do
                [[ -z "$dep" ]] && continue
                case "$dep" in
                    @rpath/*)
                        local base
                        base="$(basename "$dep")"
                        if [[ ! -f "$FRAMEWORKS_DIR/$base" && -f "$vcpkg_lib/$base" ]]; then
                            cp "$vcpkg_lib/$base" "$FRAMEWORKS_DIR/$base"
                            log "Deployed missing vcpkg dylib: $base"
                            added=1
                        fi
                        ;;
                esac
            done < <(otool -L "$dylib" 2>/dev/null | tail -n +2 | awk '{print $1}' || true)
        done < <(find "$FRAMEWORKS_DIR" "$plugins_dir" -type f -name '*.dylib' 2>/dev/null || true)
        passes=$((passes + 1))
    done

    # Normalize install names of dylibs copied from vcpkg: keep them relocatable
    # via @rpath so other dylibs can find them in Frameworks.
    for dylib in "$FRAMEWORKS_DIR"/*.dylib; do
        [[ -f "$dylib" ]] || continue
        local old_id
        old_id="$(otool -D "$dylib" 2>/dev/null | tail -1 || true)"
        if [[ -n "$old_id" && "$old_id" != @rpath/* && "$old_id" != @loader_path/* && "$old_id" != @executable_path/* ]]; then
            install_name_tool -id "@rpath/$(basename "$old_id")" "$dylib" 2>/dev/null || true
            log "Normalized install name for $(basename "$dylib"): $old_id"
        fi
    done
}

# -----------------------------------------------
# 4. Original Qt framework dylib path fixup
# -----------------------------------------------
QT_FRAMEWORKS=()
while IFS= read -r -d '' framework; do
    QT_FRAMEWORKS+=("$framework")
done < <(find "$FRAMEWORKS_DIR" -type d -name "Qt*.framework" -print0 2>/dev/null || true)

QT_FRAMEWORK_NAMES=()
for framework in "${QT_FRAMEWORKS[@]}"; do
    framework_name=$(basename "$framework" .framework)
    framework_binary="$framework/Versions/A/$framework_name"
    if [[ -f "$framework_binary" ]]; then
        QT_FRAMEWORK_NAMES+=("$framework_name")
        log "Found Qt framework: $framework_name"
    fi
done

get_framework_rpath() {
    local framework_name="$1"
    echo "@rpath/$framework_name.framework/Versions/A/$framework_name"
}

has_framework() {
    local framework_name="$1"
    for name in "${QT_FRAMEWORK_NAMES[@]}"; do
        if [[ "$name" == "$framework_name" ]]; then
            return 0
        fi
    done
    return 1
}

fix_dylib() {
    local dylib="$1"
    local changed=false

    local deps
    deps=$(otool -L "$dylib" 2>/dev/null | grep -E "Qt.*\.framework" | awk '{print $1}' || true)

    if [[ -n "$deps" ]]; then
        while IFS= read -r dep; do
            [[ -z "$dep" ]] && continue
            if [[ "$dep" != @* ]]; then
                if [[ "$dep" =~ ([^/]+)\.framework ]]; then
                    framework_name="${BASH_REMATCH[1]}"
                    if has_framework "$framework_name"; then
                        new_path=$(get_framework_rpath "$framework_name")
                        log "Fixing $dylib: $dep -> $new_path"
                        if install_name_tool -change "$dep" "$new_path" "$dylib" 2>/dev/null; then
                            changed=true
                        else
                            echo "Warning: Failed to fix $dep in $dylib" >&2
                        fi
                    fi
                fi
            fi
        done <<< "$deps"
    fi

    local rpaths
    rpaths=$(otool -l "$dylib" 2>/dev/null | grep -A2 "LC_RPATH" | grep "path" | awk '{print $2}' || true)

    if [[ "$rpaths" != *"@loader_path/../Frameworks"* ]] && [[ "$rpaths" != *"@executable_path/../Frameworks"* ]]; then
        log "Adding @loader_path/../Frameworks to $dylib"
        install_name_tool -add_rpath "@loader_path/../Frameworks" "$dylib" 2>/dev/null || {
            install_name_tool -add_rpath "@executable_path/../Frameworks" "$dylib" 2>/dev/null || {
                echo "Warning: Failed to add rpath to $dylib" >&2
            }
        }
        changed=true
    fi

    if [[ "$changed" == "true" ]]; then
        log "Fixed dylib: $dylib"
    fi
}

# -----------------------------------------------
# Main
# -----------------------------------------------
deploy_qt_translations
fix_ffmpeg_dylibs
deploy_missing_vcpkg_dylibs

dylib_count=0
fixed_count=0

while IFS= read -r -d '' dylib; do
    dylib_count=$((dylib_count + 1))
    if fix_dylib "$dylib"; then
        fixed_count=$((fixed_count + 1))
    fi
done < <(find "$FRAMEWORKS_DIR" -type f -name "*.dylib" -print0 2>/dev/null || true)

executable="$BUNDLE_DIR/Contents/MacOS/$APP_NAME"
if [[ -f "$executable" ]]; then
    dylib_count=$((dylib_count + 1))
    if fix_dylib "$executable"; then
        fixed_count=$((fixed_count + 1))
    fi
fi

log "Processed $dylib_count files, fixed $fixed_count"

# NOTE: Code signing is intentionally NOT done here. CMake adds the signing
# command as the very last POST_BUILD step, after all resource/plugin copy
# steps, so the seal covers the final bundle contents.
