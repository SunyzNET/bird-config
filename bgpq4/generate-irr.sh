#!/bin/bash
set -e

AS_SET="${AS_SET:-AS-SUNYZ}"
ASN_LOCAL="${ASN_LOCAL:-150289}"
IRR_OUTPUT="${IRR_OUTPUT:-irr.conf}"
DOWNSTREAM_OUTPUT="${DOWNSTREAM_OUTPUT:-downstream.conf}"
WHOIS_SERVER="${WHOIS_SERVER:-whois.radb.net}"
IRR_SOURCES="${IRR_SOURCES:-ARIN,RIPE,AFRINIC,APNIC,LACNIC,RADB,ALTDB}"

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

TMP_IPV4_SELF="$TMP_DIR/ipv4_self"
TMP_IPV6_SELF="$TMP_DIR/ipv6_self"
TMP_ASN_DOWN_DEFINE="$TMP_DIR/asn_down_define"
TMP_ASN_DOWN_FILTERED="$TMP_DIR/asn_down_filtered"

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

# --------------------------
# Generate irr.conf
# --------------------------
> "$IRR_OUTPUT"

if [[ -n "$ASN_LOCAL" ]]; then
  echo "Fetching Prefixes for AS${ASN_LOCAL}..."
  bgpq4 -h "$WHOIS_SERVER" -S "$IRR_SOURCES" -b -4 "AS${ASN_LOCAL}" 2>/dev/null \
    | extract_set > "$TMP_IPV4_SELF" || true
  bgpq4 -h "$WHOIS_SERVER" -S "$IRR_SOURCES" -b -6 "AS${ASN_LOCAL}" 2>/dev/null \
    | extract_set > "$TMP_IPV6_SELF" || true
fi

DOWNSTREAM_ASNS=()
if [[ -n "$AS_SET" ]]; then
  echo "Fetching Downstream ASNs for ${AS_SET}..."

  bgpq4 -h "$WHOIS_SERVER" -S "$IRR_SOURCES" -t -b "$AS_SET" 2>/dev/null \
    | extract_set > "$TMP_ASN_DOWN_DEFINE" || true

  if [[ -s "$TMP_ASN_DOWN_DEFINE" ]]; then
    grep -v "^${ASN_LOCAL},$" "$TMP_ASN_DOWN_DEFINE" > "$TMP_ASN_DOWN_FILTERED" || true
  else
    : > "$TMP_ASN_DOWN_FILTERED"
  fi

  while read -r line; do
    asn="${line%,}"
    [[ -z "$asn" ]] && continue
    DOWNSTREAM_ASNS+=("$asn")
  done < "$TMP_ASN_DOWN_FILTERED"
fi

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
} >> "$IRR_OUTPUT"

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
    } >> "$IRR_OUTPUT"
  done
fi

echo "Done. Wrote: $IRR_OUTPUT"

# --------------------------
# Generate downstream.conf
# --------------------------
> "$DOWNSTREAM_OUTPUT"

{
	echo "function downstream_import_filter(int ASN) -> bool {"
	printf '\tif !is_valid() then return false;\n'
	printf '\tlc_add_in(ASN, 2);\n'
	printf '\tif !is_downstream_asn() then return false;\n'
	printf '\n'
	printf '\tcase net.type {\n'

	# ---------------- IPv4 ----------------
	printf '\t\tNET_IP4: {\n'

	# Special ASN 114514: global match across all downstream prefix lists (IRR + CUSTOM)
	printf '\t\t\tif (ASN = 114514) then {\n'
	for asn in "${DOWNSTREAM_ASNS[@]}"; do
		printf '\t\t\t\tif (net ~ DOWNSTREAM_PREFIXES_AS%s_IPV4) || (net ~ DOWNSTREAM_PREFIXES_AS%s_CUSTOM_IPV4) then return true;\n' "$asn" "$asn"
	done
	printf '\t\t\t\treturn false;\n'
	printf '\t\t\t}\n'

	# Normal case: ASN must be downstream, and match only its own IRR/CUSTOM list
	printf '\t\t\tif !(ASN ~ ASN_DOWNSTREAM) then return false;\n'
	for asn in "${DOWNSTREAM_ASNS[@]}"; do
		printf '\t\t\tif (ASN = %s) then return (net ~ DOWNSTREAM_PREFIXES_AS%s_IPV4) || (net ~ DOWNSTREAM_PREFIXES_AS%s_CUSTOM_IPV4);\n' "$asn" "$asn" "$asn"
	done
	printf '\t\t\treturn false;\n'
	printf '\t\t}\n'

	# ---------------- IPv6 ----------------
	printf '\t\tNET_IP6: {\n'

	# Special ASN 114514: global match across all downstream prefix lists (IRR + CUSTOM)
	printf '\t\t\tif (ASN = 114514) then {\n'
	for asn in "${DOWNSTREAM_ASNS[@]}"; do
		printf '\t\t\t\tif (net ~ DOWNSTREAM_PREFIXES_AS%s_IPV6) || (net ~ DOWNSTREAM_PREFIXES_AS%s_CUSTOM_IPV6) then return true;\n' "$asn" "$asn"
	done
	printf '\t\t\t\treturn false;\n'
	printf '\t\t\t}\n'

	# Normal case: ASN must be downstream, and match only its own IRR/CUSTOM list
	printf '\t\t\tif !(ASN ~ ASN_DOWNSTREAM) then return false;\n'
	for asn in "${DOWNSTREAM_ASNS[@]}"; do
		printf '\t\t\tif (ASN = %s) then return (net ~ DOWNSTREAM_PREFIXES_AS%s_IPV6) || (net ~ DOWNSTREAM_PREFIXES_AS%s_CUSTOM_IPV6);\n' "$asn" "$asn" "$asn"
	done
	printf '\t\t\treturn false;\n'
	printf '\t\t}\n'

	# ---------------- else ----------------
	printf '\t\telse: {\n'
	printf '\t\t\tprint "downstream_import_filter: unexpected net.type ", net.type, " ", net;\n'
	printf '\t\t\treturn false;\n'
	printf '\t\t}\n'

	printf '\t}\n'
	echo "}"
} >> "$DOWNSTREAM_OUTPUT"

echo "Done. Wrote: $DOWNSTREAM_OUTPUT"