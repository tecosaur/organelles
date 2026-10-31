#!/usr/bin/env bash

set -euo pipefail

declare -A svgs_formatted=()

svgfmt () {
    local infile="$1"
    [[ -n "${svgs_formatted["$infile"]+x}" ]] && return 0
    sed -i "s/$PRIMARY_STANDIN/$PRIMARY_COLOR/g" "$infile"
    sed -i "s/$SECONDARY_STANDIN/$SECONDARY_COLOR/g" "$infile"
    svgo --input="$infile" --output="$infile" --multipass
    svgs_formatted["$infile"]=1
}

# A maskable icon: the artwork in the middle 60%, within the safe zone a launcher's mask always
# keeps, on a solid background
svg2maskable () {
    local infile="$1" outfile="$2" size="$3" background="$4" inner offset
    inner=$(( size * 3 / 5 ))
    offset=$(( (size - inner) / 2 ))
    svgfmt "$infile"
    rsvg-convert -w "$inner" -h "$inner" --page-width "$size" --page-height "$size" \
        --left "$offset" --top "$offset" -b "$background" -f png -o "$outfile" "$infile"
    pngopt "$outfile"
}

pngopt () {
    local infile="$1"
    # Use `pngquant` then `oxipng`,
    # based on <https://github.com/kornelski/pngquant/issues/386>.
    pngquant --force --ext .png --skip-if-larger --speed 1 --strip "$infile" || {
        [ "$?" -eq 98 ] || return $?
    }
    oxipng -o max --strip safe --alpha --fast --zopfli "$infile"
}

svg2png () {
    local infile="$1"
    shift || return 2
    local outfile
    if [[ $# -gt 0 && "$1" != -* ]]; then
        outfile="$1"
        shift
    else
        # default: replace .svg with .png (or just append .png)
        outfile="${infile%.svg}.png"
    fi
    svgfmt "$infile"
    rsvg-convert "$@" -f png -o "$outfile" "$infile"
    pngopt "$outfile"
}

favmake () {
    local replace=0
    local infile=""
    local outfile=""
    while (($#)); do
        case "$1" in
            --replace) replace=1; shift ;;
            --) shift ;;
            --*) 
                echo "favmake: unrecognized option '$1'" >&2
                return 2
                ;;
            *)
                if [ -z "$infile" ]; then
                    infile="$1"
                elif [ -z "$outfile" ]; then
                    outfile="$1"
                else
                    echo "favmake: too many arguments" >&2
                    return 2
                fi
                shift
                ;;
        esac
    done
    if [ -d "$infile" ]; then
        infile="$infile/favicon.svg"
    fi
    if [ -z "$outfile" ]; then
        outfile="$(dirname "$infile")/favicon.ico"
    fi
    svg2png "$infile" "$infile-f16.png" -w 16 -h 16
    svg2png "$infile" "$infile-f32.png" -w 32 -h 32
    svg2png "$infile" "$infile-f48.png" -w 48 -h 48
    echo "
from PIL import Image
images = [Image.open('$infile-f16.png'),
          Image.open('$infile-f32.png'),
          Image.open('$infile-f48.png')]
images[-1].save('$outfile', sizes=[img.size for img in images], append_images=images[:-1])
" | python3
    rm -- "$infile-f16.png" "$infile-f32.png" "$infile-f48.png"
    if (( replace )); then
        rm -- "$infile"
    fi
}
