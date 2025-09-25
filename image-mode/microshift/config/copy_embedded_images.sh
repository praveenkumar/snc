#!/bin/bash
set -euxo pipefail

# Verify mapping file exists
if [[ ! -f /usr/lib/containers-image-cache/mapping.txt ]]; then
    echo "Error: mapping file not found" >&2
    exit 1
fi

while IFS="," read -r image sha
do
    # Skip empty lines
    [[ -n "$image" && -n "$sha" ]] || continue

    # Validate sha contains only expected characters (alphanumeric, hyphens)
    if [[ ! "$sha" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "Error: Invalid sha format: $sha" >&2
        exit 1
    fi

    # Verify source directory exists
    if [[ ! -d "/usr/lib/containers-image-cache/$sha" ]]; then
        echo "Error: Source directory not found for sha: $sha" >&2
        exit 1
    fi

    skopeo copy --preserve-digests dir:/usr/lib/containers-image-cache/$sha containers-storage:$image
done < /usr/lib/containers-image-cache/mapping.txt

rm -fr /usr/lib/containers-image-cache
