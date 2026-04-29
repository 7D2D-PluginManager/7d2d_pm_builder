#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGURATION="Release"
SERVER_ROOT="${SDTD_SERVER_ROOT:-/home/sdtdtest/serverfiles}"
OUT_DIR="$ROOT_DIR/build"
CLEAN=1

usage() {
    cat <<USAGE
Usage: ./build.sh [options]

Options:
  -c, --configuration <Debug|Release>   Build configuration. Default: Release.
  -s, --server-root <path>              7 Days to Die server root. Default: \$SDTD_SERVER_ROOT or /home/sdtdtest/serverfiles.
  -o, --out <path>                      Output directory. Default: ./build.
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

if [[ "$CLEAN" -eq 1 ]]; then
    rm -rf "$OUT_DIR"
fi

mkdir -p "$REFS_DIR" "$MOD_DIR" "$PLUGINS_DIR"

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
}

copy_shared_library() {
    local name="$1"
    if [[ -f "$REFS_DIR/$name.dll" ]]; then
        cp -f "$REFS_DIR/$name.dll" "$MOD_DIR/$name.dll"
    fi
    if [[ -f "$REFS_DIR/$name.pdb" ]]; then
        cp -f "$REFS_DIR/$name.pdb" "$MOD_DIR/$name.pdb"
    fi
}

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

copy_shared_library PluginManager.Api
copy_shared_library PluginManager.Config
copy_shared_library PluginManager.Localization

plugin_projects=(
    "HomePlugin|$ROOT_DIR/7d2d_pm_home/src/HomePlugin/HomePlugin.csproj|$ROOT_DIR/7d2d_pm_home/static"
    "PlayerChatDecor|$ROOT_DIR/7d2d_pm_player_chat_decor/src/PlayerChatDecor/PlayerChatDecor.csproj|$ROOT_DIR/7d2d_pm_player_chat_decor/static"
    "TileClaimProtector|$ROOT_DIR/7d2d_pm_tile_clime_protector/src/TileClaimProtector/TileClaimProtector.csproj|"
    "TpaPlugin|$ROOT_DIR/7d2d_pm_tpa/src/TpaPlugin/TpaPlugin.csproj|$ROOT_DIR/7d2d_pm_tpa/static"
    "WelcomeMessage|$ROOT_DIR/7d2d_pm_welcome_mesage/src/WelcomeMessage/WelcomeMessage.csproj|"
)

loaded_plugins=()

echo "==> Building plugins"
for entry in "${plugin_projects[@]}"; do
    IFS='|' read -r plugin_name project_path static_path <<< "$entry"
    plugin_output="$PLUGINS_DIR/$plugin_name"

    properties=("PluginManagerApiPath=$MOD_DIR/")
    if [[ -n "$static_path" ]]; then
        properties+=("StaticPath=$static_path/")
    fi

    msbuild_project "$project_path" "$plugin_output" "${properties[@]}"
    loaded_plugins+=("$plugin_name")
done

mkdir -p "$MOD_DIR/Config"
printf "%s\n" "${loaded_plugins[@]}" > "$MOD_DIR/Config/plugins.txt"

rm -rf "$STAGING_DIR"

echo
echo "Build completed:"
echo "  $MOD_DIR"
echo
echo "Install by copying '$OUT_DIR/Mods/1_PluginManager' to '$SERVER_ROOT/Mods/1_PluginManager'."
