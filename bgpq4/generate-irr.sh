#!/bin/bash
set -e

# Environment Variables
AS_SET="${AS_SET:-AS-SUNYZ}"
ASN_LOCAL="${ASN_LOCAL:-150289}"
OUTPUT="${OUTPUT:-irr.conf}"
WHOIS_SERVER="${WHOIS_SERVER:-whois.radb.net}"
IRR_SOURCES="${IRR_SOURCES:-ARIN,RIPE,AFRINIC,APNIC,LACNIC,RADB,ALTDB}"

TMP_IPV4_SELF=$(mktemp)
TMP_IPV6_SELF=$(mktemp)
TMP_IPV4_DOWN=$(mktemp)
TMP_IPV6_DOWN=$(mktemp)
TMP_ASN_DOWN=$(mktemp)

cleanup() { rm -f "$TMP_IPV4_SELF" "$TMP_IPV6_SELF" "$TMP_IPV4_DOWN" "$TMP_IPV6_DOWN" "$TMP_ASN_DOWN"; }
trap cleanup EXIT

extract_set() {
  awk '/\[/,/\]/' \
    | sed '1d;$d' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | sed '/^$/d' \
    | sed 's/,*$//' \
    | sed 's/$/,/'
}

emit_list() {
    local file="$1"
    if [[ ! -s "$file" ]]; then
        return 0
    fi

    awk '
        { buf[NR] = $0 }
        END {
            if (NR == 1) {
                sub(/,[[:space:]]*$/, "", buf[1]);
                print "\t" buf[1];
            } else {
                for (i = 1; i < NR; i++) {
                print "\t" buf[i];
                }
                sub(/,[[:space:]]*$/, "", buf[NR]);
                print "\t" buf[NR];
            }
        }
    ' "$file"
}


# Empty the File
> "$OUTPUT"

# Self Prefixes
if [[ -n "$ASN_LOCAL" ]]; then
    echo "Fetching Prefixes for AS${ASN_LOCAL}..."
    bgpq4 -h "$WHOIS_SERVER" -S "$IRR_SOURCES" -b -4 "AS${ASN_LOCAL}" 2>/dev/null \
        | extract_set > "$TMP_IPV4_SELF" || true
    bgpq4 -h "$WHOIS_SERVER" -S "$IRR_SOURCES" -b -6 "AS${ASN_LOCAL}" 2>/dev/null \
        | extract_set > "$TMP_IPV6_SELF" || true
fi

# Downstream Prefixes
if [[ -n "$AS_SET" ]]; then
    echo "Fetching Downstream Data for ${AS_SET}..."
    bgpq4 -h "$WHOIS_SERVER" -S "$IRR_SOURCES" -t -b "$AS_SET" 2>/dev/null \
        | extract_set > "$TMP_ASN_DOWN" || true
    bgpq4 -h "$WHOIS_SERVER" -S "$IRR_SOURCES" -b -4 "$AS_SET" 2>/dev/null \
        | extract_set > "$TMP_IPV4_DOWN" || true
    bgpq4 -h "$WHOIS_SERVER" -S "$IRR_SOURCES" -b -6 "$AS_SET" 2>/dev/null \
        | extract_set > "$TMP_IPV6_DOWN" || true
fi

# Output
{
    echo "define SELF_PREFIXES_IPV4 = ["
    emit_list "$TMP_IPV4_SELF"
    echo "];"
    echo

    echo "define SELF_PREFIXES_IPV6 = ["
    emit_list "$TMP_IPV6_SELF"
    echo "];"
    echo

    echo "define ASN_DOWNSTREAM = ["
    emit_list "$TMP_ASN_DOWN"
    echo "];"
    echo

    echo "define DOWNSTREAM_PREFIXES_IPV4 = ["
    emit_list "$TMP_IPV4_DOWN"
    echo "];"
    echo

    echo "define DOWNSTREAM_PREFIXES_IPV6 = ["
    emit_list "$TMP_IPV6_DOWN"
    echo "];"
} >> "$OUTPUT"
