#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGURATION="Release"
SERVER_ROOT="${SDTD_SERVER_ROOT:-/home/sdtdtest/serverfiles}"
OUT_DIR="$ROOT_DIR/build"
CLEAN=1
FORCE_CORE=0

usage() {
    cat <<USAGE
Usage: ./build.sh [options]

Plugins are discovered automatically (<dir>/src/<Name>/<Name>.csproj).
An interactive menu lets you pick plugins to rebuild, press Enter for a
full rebuild, or enter 0 to exit. Without a terminal a full build runs.

Options:
  -c, --configuration <Debug|Release>   Build configuration. Default: Release.
  -s, --server-root <path>              7 Days to Die server root. Default: \$SDTD_SERVER_ROOT or /home/sdtdtest/serverfiles.
  -o, --out <path>                      Output directory. Default: ./build.
      --core                            Force rebuild of shared libraries and core on partial builds.
      --no-clean                        Keep the existing output directory.
  -h, --help                            Show this help.

Result:
  <out>/Mods/1_PluginManager
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--configuration)
            CONFIGURATION="${2:?Missing value for $1}"
            shift 2
            ;;
        -s|--server-root)
            SERVER_ROOT="${2:?Missing value for $1}"
            shift 2
            ;;
        -o|--out)
            OUT_DIR="${2:?Missing value for $1}"
            shift 2
            ;;
        --core)
            FORCE_CORE=1
            shift
            ;;
        --no-clean)
            CLEAN=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

MANAGED_DIR="$SERVER_ROOT/7DaysToDieServer_Data/Managed"
HARMONY_DIR="$SERVER_ROOT/Mods/0_TFP_Harmony"
STAGING_DIR="$OUT_DIR/_staging"
REFS_DIR="$STAGING_DIR/refs"
MOD_DIR="$OUT_DIR/Mods/1_PluginManager"
PLUGINS_DIR="$MOD_DIR/Plugins"

FRAMEWORK_PATH_OVERRIDE="${FRAMEWORK_PATH_OVERRIDE:-}"
if [[ -z "$FRAMEWORK_PATH_OVERRIDE" && -d /usr/lib/mono/4.8-api ]]; then
    FRAMEWORK_PATH_OVERRIDE="/usr/lib/mono/4.8-api"
fi

required_files=(
    "$MANAGED_DIR/Assembly-CSharp.dll"
    "$MANAGED_DIR/LogLibrary.dll"
    "$MANAGED_DIR/UnityEngine.CoreModule.dll"
    "$MANAGED_DIR/UnityEngine.AudioModule.dll"
    "$HARMONY_DIR/0Harmony.dll"
)

for file in "${required_files[@]}"; do
    if [[ ! -f "$file" ]]; then
        echo "Missing required 7DTD reference: $file" >&2
        echo "Set --server-root or SDTD_SERVER_ROOT to your 7 Days to Die server directory." >&2
        exit 1
    fi
done

if [[ -n "$FRAMEWORK_PATH_OVERRIDE" && ! -d "$FRAMEWORK_PATH_OVERRIDE" ]]; then
    echo "FRAMEWORK_PATH_OVERRIDE points to a missing directory: $FRAMEWORK_PATH_OVERRIDE" >&2
    exit 1
fi

restore_project() {
    local project="$1"
    local args=(
        restore
        "$project"
        /nologo
        /verbosity:minimal
    )

    if [[ -n "$FRAMEWORK_PATH_OVERRIDE" ]]; then
        args+=("/p:FrameworkPathOverride=$FRAMEWORK_PATH_OVERRIDE")
    fi

    dotnet "${args[@]}"
}

generate_package_reference_targets() {
    local project="$1"
    local target_file="$2"
    local project_dir
    project_dir="$(dirname "$project")"
    local assets_file="$project_dir/obj/project.assets.json"

    {
        printf '<Project xmlns="http://schemas.microsoft.com/developer/msbuild/2003">\n'
        printf '  <ItemGroup>\n'
        if [[ -f "$MANAGED_DIR/netstandard.dll" ]]; then
            printf '    <Reference Include="netstandard" Condition="Exists('\''%s'\'')">\n' "$MANAGED_DIR/netstandard.dll"
            printf '      <HintPath>%s</HintPath>\n' "$MANAGED_DIR/netstandard.dll"
            printf '      <Private>False</Private>\n'
            printf '    </Reference>\n'
        fi
        for shared_name in PluginManager.Api PluginManager.Config PluginManager.Localization; do
            if ! grep -Fq "$shared_name.dll" "$project"; then
                continue
            fi
            for shared_dir in "$MOD_DIR" "$REFS_DIR"; do
                local shared_dll="$shared_dir/$shared_name.dll"
                if [[ -f "$shared_dll" ]]; then
                    printf '    <Reference Include="%s" Condition="Exists('\''%s'\'')">\n' "$shared_name" "$shared_dll"
                    printf '      <HintPath>%s</HintPath>\n' "$shared_dll"
                    printf '      <Private>False</Private>\n'
                    printf '    </Reference>\n'
                    break
                fi
            done
        done
        printf '  </ItemGroup>\n'

        if [[ -f "$assets_file" ]] && command -v jq >/dev/null 2>&1; then
            printf '  <ItemGroup>\n'
            jq -r '
                . as $assets
                | ($assets.packageFolders | keys[0]) as $packageRoot
                | $assets.targets[]
                | to_entries[]
                | select(.value.compile != null)
                | .key as $packageKey
                | ($assets.libraries[$packageKey].path) as $packagePath
                | .value.compile
                | keys[]
                | select(test("\\.dll$"))
                | "\($packageRoot)\($packagePath)/\(.)"
            ' "$assets_file" | sort -u | while IFS= read -r dll_path; do
                local assembly_name
                assembly_name="$(basename "$dll_path" .dll)"
                printf '    <Reference Include="%s" Condition="Exists('\''%s'\'')">\n' "$assembly_name" "$dll_path"
                printf '      <HintPath>%s</HintPath>\n' "$dll_path"
                printf '      <Private>True</Private>\n'
                printf '    </Reference>\n'
            done
            printf '  </ItemGroup>\n'
        fi

        printf '</Project>\n'
    } > "$target_file"
}

copy_runtime_assets() {
    local project="$1"
    local output_path="$2"
    local project_dir
    project_dir="$(dirname "$project")"
    local assets_file="$project_dir/obj/project.assets.json"

    if [[ ! -f "$assets_file" ]] || ! command -v jq >/dev/null 2>&1; then
        return
    fi

    jq -r '
        . as $assets
        | ($assets.packageFolders | keys[0]) as $packageRoot
        | $assets.targets[]
        | to_entries[]
        | select(.value.runtime != null)
        | .key as $packageKey
        | ($assets.libraries[$packageKey].path) as $packagePath
        | .value.runtime
        | keys[]
        | select(test("\\.dll$"))
        | select(startswith("ref/") | not)
        | "\($packageRoot)\($packagePath)/\(.)"
    ' "$assets_file" | sort -u | while IFS= read -r dll_path; do
        [[ -f "$dll_path" ]] || continue
        local dll_name
        dll_name="$(basename "$dll_path")"
        if [[ "$output_path" == "$MOD_DIR" && "$dll_name" == System*.dll && -f "$MANAGED_DIR/$dll_name" ]]; then
            continue
        fi
        cp -f "$dll_path" "$output_path/$dll_name"

        local xml_path="${dll_path%.dll}.xml"
        if [[ -f "$xml_path" ]]; then
            cp -f "$xml_path" "$output_path/$(basename "$xml_path")"
        fi
    done
}

msbuild_project() {
    local project="$1"
    local output_path="$2"
    shift 2

    mkdir -p "$output_path"

    restore_project "$project"

    local package_targets="$STAGING_DIR/$(basename "$project" .csproj).PackageReferences.targets"
    generate_package_reference_targets "$project" "$package_targets"

    local args=(
        msbuild
        "$project"
        /nologo
        /verbosity:minimal
        /p:Configuration="$CONFIGURATION"
        /p:Platform=AnyCPU
        /p:OutputPath="$output_path/"
        /p:AutoGenerateBindingRedirects=false
        /p:CustomAfterMicrosoftCommonTargets="$package_targets"
    )

    if [[ -n "$FRAMEWORK_PATH_OVERRIDE" ]]; then
        args+=(/p:FrameworkPathOverride="$FRAMEWORK_PATH_OVERRIDE")
    fi

    for property in "$@"; do
        args+=("/p:$property")
    done

    dotnet "${args[@]}"
    copy_runtime_assets "$project" "$output_path"
}

copy_staged_libraries() {
    find "$REFS_DIR" -maxdepth 1 -type f \( -name '*.dll' -o -name '*.pdb' -o -name '*.xml' \) \
        ! -name 'System*.dll' \
        ! -name 'System*.xml' \
        -exec cp -f {} "$MOD_DIR/" \;
}

remove_system_libraries_from_mod_root() {
    find "$MOD_DIR" -maxdepth 1 -type f \( -name 'System*.dll' -o -name 'System*.xml' \) -print0 \
        | while IFS= read -r -d '' file; do
            local base
            base="$(basename "$file")"
            base="${base%.xml}"
            base="${base%.dll}"
            if [[ -f "$MANAGED_DIR/$base.dll" ]]; then
                rm -f "$file"
            fi
        done
}

discover_plugins() {
    PLUGIN_NAMES=()
    PLUGIN_PROJECTS=()
    PLUGIN_STATICS=()
    PLUGIN_MODULES=()

    local name csproj static_path module_name
    while IFS='|' read -r name csproj static_path module_name; do
        PLUGIN_NAMES+=("$name")
        PLUGIN_PROJECTS+=("$csproj")
        PLUGIN_STATICS+=("$static_path")
        PLUGIN_MODULES+=("$module_name")
    done < <(
        find "$ROOT_DIR" -mindepth 4 -maxdepth 4 -path "$ROOT_DIR/*/src/*/*.csproj" \
            ! -path "$ROOT_DIR/build/*" ! -path "$OUT_DIR/*" ! -name 'PluginManager.*.csproj' \
        | while IFS= read -r csproj; do
            name="$(basename "$csproj" .csproj)"
            local plugin_root
            plugin_root="$(dirname "$(dirname "$(dirname "$csproj")")")"
            static_path=""
            if [[ -d "$plugin_root/static" ]]; then
                static_path="$plugin_root/static"
            fi
            module_name="$(grep -rhoP 'ModuleName\s*=>\s*"\K[^"]+' "$plugin_root/src" 2>/dev/null | head -n 1 || true)"
            printf '%s|%s|%s|%s\n' "$name" "$csproj" "$static_path" "${module_name:-$name}"
        done | sort -t'|' -k1,1
    )
}

select_plugins() {
    echo "Discovered plugins:"
    local i
    for i in "${!PLUGIN_MODULES[@]}"; do
        printf '  %2d) %s\n' "$((i + 1))" "${PLUGIN_MODULES[$i]}"
    done
    echo

    local input token valid indices
    while true; do
        read -r -p "Select (numbers separated by spaces, Enter = full rebuild, 0 = exit): " input
        input="${input//,/ }"

        if [[ -z "${input// /}" ]]; then
            return 0
        fi

        valid=1
        indices=()
        for token in $input; do
            if [[ "$token" == "0" ]]; then
                echo "Exit."
                exit 0
            fi
            if ! [[ "$token" =~ ^[0-9]+$ ]] || (( token < 1 || token > ${#PLUGIN_NAMES[@]} )); then
                echo "Invalid selection: $token" >&2
                valid=0
                break
            fi
            indices+=("$((token - 1))")
        done

        if [[ "$valid" -eq 1 ]]; then
            mapfile -t SELECTED_INDICES < <(printf '%s\n' "${indices[@]}" | sort -nu)
            return 0
        fi
    done
}

build_core() {
    echo "==> Building shared PluginManager libraries"
    msbuild_project "$ROOT_DIR/7d2d_plugin_manager_api/src/PluginManager.Api/PluginManager.Api.csproj" "$REFS_DIR"
    msbuild_project "$ROOT_DIR/7d2d_plugin_manager_config/src/PluginManager.Config/PluginManager.Config.csproj" "$REFS_DIR"
    msbuild_project "$ROOT_DIR/7d2d_plugin_manager_localization/src/PluginManager.Localization/PluginManager.Localization.csproj" "$REFS_DIR" \
        "PluginManagerApiPath=$REFS_DIR/"

    echo "==> Building PluginManager core mod"
    msbuild_project "$ROOT_DIR/7d2d_plugin_manager_core/src/PluginManager.Core/PluginManager.Core.csproj" "$MOD_DIR" \
        "PluginManagerApiPath=$REFS_DIR/" \
        "GameLibsPath=$MANAGED_DIR/" \
        "HarmonyPath=$HARMONY_DIR/" \
        "StaticPath=$ROOT_DIR/7d2d_plugin_manager_core/static/"

    copy_staged_libraries
    remove_system_libraries_from_mod_root
}

build_plugin() {
    local index="$1"
    local plugin_name="${PLUGIN_NAMES[$index]}"
    local project_path="${PLUGIN_PROJECTS[$index]}"
    local static_path="${PLUGIN_STATICS[$index]}"
    local plugin_tmp="$STAGING_DIR/plugin_$plugin_name"

    echo "==> Building plugin: ${PLUGIN_MODULES[$index]}"
    rm -rf "$plugin_tmp"
    mkdir -p "$plugin_tmp" "$MOD_DIR/Config" "$MOD_DIR/Lang"

    local properties=("PluginManagerApiPath=$MOD_DIR/" "GameLibsPath=$MANAGED_DIR/")
    if [[ -n "$static_path" ]]; then
        properties+=("StaticPath=$static_path/")
    fi

    msbuild_project "$project_path" "$plugin_tmp" "${properties[@]}"

    cp -f "$plugin_tmp/$plugin_name.dll" "$PLUGINS_DIR/$plugin_name.dll"
    if [[ -f "$plugin_tmp/$plugin_name.pdb" ]]; then
        cp -f "$plugin_tmp/$plugin_name.pdb" "$PLUGINS_DIR/$plugin_name.pdb"
    fi

    find "$plugin_tmp" -maxdepth 1 -type f \( -name '*.dll' -o -name '*.xml' \) | while IFS= read -r dep; do
        local base stem
        base="$(basename "$dep")"
        case "$base" in
            "$plugin_name.dll"|"$plugin_name.xml") continue ;;
            System*|PluginManager.*) continue ;;
        esac
        stem="${base%.*}"
        [[ -f "$MANAGED_DIR/$stem.dll" ]] && continue
        [[ -f "$MOD_DIR/$base" ]] && continue
        cp -f "$dep" "$MOD_DIR/$base"
    done

    if [[ -n "$static_path" && -f "$static_path/config.json" ]]; then
        cp -f "$static_path/config.json" "$MOD_DIR/Config/$plugin_name.json"
    fi

    local lang_src=""
    if [[ -n "$static_path" && -d "$static_path/lang" ]]; then
        lang_src="$static_path/lang"
    elif [[ -n "$static_path" && -d "$(dirname "$static_path")/lang" ]]; then
        lang_src="$(dirname "$static_path")/lang"
    fi

    if [[ -n "$lang_src" ]]; then
        for f in "$lang_src"/*.json; do
            [[ -f "$f" ]] || continue
            local culture
            culture="$(basename "$f" .json)"
            cp -f "$f" "$MOD_DIR/Lang/$plugin_name.$culture.json"
        done
    fi
}

discover_plugins

if [[ "${#PLUGIN_NAMES[@]}" -eq 0 ]]; then
    echo "No plugin projects found under $ROOT_DIR (<dir>/src/<Name>/<Name>.csproj)." >&2
    exit 1
fi

SELECTED_INDICES=()
if [[ -t 0 ]]; then
    select_plugins
fi

if [[ "${#SELECTED_INDICES[@]}" -eq 0 ]]; then
    if [[ "$CLEAN" -eq 1 ]]; then
        rm -rf "$OUT_DIR"
    fi
    mkdir -p "$REFS_DIR" "$MOD_DIR" "$PLUGINS_DIR" "$MOD_DIR/Config" "$MOD_DIR/Lang" "$MOD_DIR/Data"

    build_core

    for i in "${!PLUGIN_NAMES[@]}"; do
        build_plugin "$i"
    done
else
    mkdir -p "$REFS_DIR" "$MOD_DIR" "$PLUGINS_DIR" "$MOD_DIR/Config" "$MOD_DIR/Lang" "$MOD_DIR/Data"

    if [[ "$FORCE_CORE" -eq 1 || ! -f "$MOD_DIR/PluginManager.Core.dll" ]]; then
        build_core
    fi

    for i in "${SELECTED_INDICES[@]}"; do
        build_plugin "$i"
    done
fi

mkdir -p "$PLUGINS_DIR/disabled"

rm -rf "$STAGING_DIR"

echo
echo "Build completed:"
echo "  $MOD_DIR"
echo
echo "Install by copying '$OUT_DIR/Mods/1_PluginManager' to '$SERVER_ROOT/Mods/1_PluginManager'."
