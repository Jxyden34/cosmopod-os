# CVE-2026-43895 updates both the grammar and its shipped generated parser.
# Patch applies parser.c before parser.y, leaving the grammar fractionally newer;
# jq's non-maintainer build intentionally cannot regenerate parser.c.  Align the
# generated files with the grammar so the supplied, patched parser is used.
do_configure:prepend() {
    touch -r ${S}/src/parser.y ${S}/src/parser.c ${S}/src/parser.h
}
