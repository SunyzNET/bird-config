#!/bin/bash
set -e

# Environment Variables
AS_SET="${AS_SET:-AS-SUNYZ}"
ASN_LOCAL="${ASN_LOCAL:-150289}"
OUTPUT="${OUTPUT:-irr.conf}"
WHOIS_SERVER="${WHOIS_SERVER:-whois.radb.net}"
IRR_SOURCES="${IRR_SOURCES:-ARIN,RIPE,AFRINIC,APNIC,LACNIC,RADB,ALTDB}"

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

TMP_IPV4_SELF="$TMP_DIR/ipv4_self"
TMP_IPV6_SELF="$TMP_DIR/ipv6_self"
TMP_ASN_DOWN_DEFINE="$TMP_DIR/asn_down_define"
TMP_ASN_DOWN_FILTERED="$TMP_DIR/asn_down_filtered"
TMP_IPV4_DOWN="$TMP_DIR/ipv4_down"
TMP_IPV6_DOWN="$TMP_DIR/ipv6_down"

# Robust: extract list items between [ ] and split commas into lines
extract_set() {
  awk '
    /\[/ {inside=1; next}
    /\]/ {inside=0; next}
    inside==1 {print}
  ' \
  | tr ',' '\n' \
  | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
  | sed '/^$/d' \
  | sed 's/;$//' \
  | sed 's/$/,/'
}

emit_list() {
  local file="$1"
  [[ ! -s "$file" ]] && return 0

  awk '
    { buf[NR] = $0 }
    END {
      if (NR == 1) {
        sub(/,[[:space:]]*$/, "", buf[1]);
        print "\t" buf[1];
      } else {
        for (i = 1; i < NR; i++) print "\t" buf[i];
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

# Downstream ASNs + Downstream aggregate prefixes
DOWNSTREAM_ASNS=()
if [[ -n "$AS_SET" ]]; then
  echo "Fetching Downstream Data for ${AS_SET}..."

  # Downstream ASN list from AS-SET
  bgpq4 -h "$WHOIS_SERVER" -S "$IRR_SOURCES" -t -b "$AS_SET" 2>/dev/null \
    | extract_set > "$TMP_ASN_DOWN_DEFINE" || true

  # Filter out local ASN (so it won't be treated as downstream)
  if [[ -s "$TMP_ASN_DOWN_DEFINE" ]]; then
    grep -v "^${ASN_LOCAL},$" "$TMP_ASN_DOWN_DEFINE" > "$TMP_ASN_DOWN_FILTERED" || true
  else
    : > "$TMP_ASN_DOWN_FILTERED"
  fi

  # Build array of downstream ASNs (numbers)
  while read -r line; do
    asn="${line%,}"
    [[ -z "$asn" ]] && continue
    DOWNSTREAM_ASNS+=("$asn")
  done < "$TMP_ASN_DOWN_FILTERED"

  # Aggregate downstream prefixes for whole AS-SET (you asked to generate these again)
  bgpq4 -h "$WHOIS_SERVER" -S "$IRR_SOURCES" -b -4 "$AS_SET" 2>/dev/null \
    | extract_set > "$TMP_IPV4_DOWN" || true
  bgpq4 -h "$WHOIS_SERVER" -S "$IRR_SOURCES" -b -6 "$AS_SET" 2>/dev/null \
    | extract_set > "$TMP_IPV6_DOWN" || true
fi

# Output base lists
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
  emit_list "$TMP_ASN_DOWN_FILTERED"
  echo "];"
  echo

  echo "define DOWNSTREAM_PREFIXES_IPV4 = ["
  emit_list "$TMP_IPV4_DOWN"
  echo "];"
  echo

  echo "define DOWNSTREAM_PREFIXES_IPV6 = ["
  emit_list "$TMP_IPV6_DOWN"
  echo "];"
  echo
} >> "$OUTPUT"

# Per-downstream ASN prefix lists
if [[ "${#DOWNSTREAM_ASNS[@]}" -gt 0 ]]; then
  echo "Fetching Per-Downstream Prefix Lists..."
  for asn in "${DOWNSTREAM_ASNS[@]}"; do
    tmp4="$TMP_DIR/as${asn}_v4"
    tmp6="$TMP_DIR/as${asn}_v6"

    echo "  - AS${asn} IPv4/IPv6..."
    bgpq4 -h "$WHOIS_SERVER" -S "$IRR_SOURCES" -b -4 "AS${asn}" 2>/dev/null \
      | extract_set > "$tmp4" || true
    bgpq4 -h "$WHOIS_SERVER" -S "$IRR_SOURCES" -b -6 "AS${asn}" 2>/dev/null \
      | extract_set > "$tmp6" || true

    {
      echo "define DOWNSTREAM_PREFIXES_AS${asn}_IPV4 = ["
      emit_list "$tmp4"
      echo "];"
      echo

      echo "define DOWNSTREAM_PREFIXES_AS${asn}_IPV6 = ["
      emit_list "$tmp6"
      echo "];"
      echo
    } >> "$OUTPUT"
  done
fi

# Function: downstream_import_filter(int ASN) -> bool
{
	echo "function downstream_import_filter(int ASN) -> bool {"
	echo -e "\tif !is_valid() then return false;"
	echo -e "\tlc_add_in(ASN, 2);"
	echo -e "\tif !(ASN ~ ASN_DOWNSTREAM) then return false;"
	echo
	echo -e "\tcase net.type {"
	echo -e "\t\tNET_IP4: {"
	for asn in "${DOWNSTREAM_ASNS[@]}"; do
		echo -e "\t\t\tif (ASN = ${asn}) then return net ~ DOWNSTREAM_PREFIXES_AS${asn}_IPV4;"
	done
	echo -e "\t\t\treturn false;"
	echo -e "\t\t}"
	echo -e "\t\tNET_IP6: {"
	for asn in "${DOWNSTREAM_ASNS[@]}"; do
		echo -e "\t\t\tif (ASN = ${asn}) then return net ~ DOWNSTREAM_PREFIXES_AS${asn}_IPV6;"
	done
	echo -e "\t\t\treturn false;"
	echo -e "\t\t}"
	echo -e "\t\telse: {"
	echo -e "\t\t\tprint \"downstream_import_filter: unexpected net.type \", net.type, \" \", net;"
	echo -e "\t\t\treturn false;"
	echo -e "\t\t}"
	echo -e "\t}"
	echo "}"
} >> "$OUTPUT"
