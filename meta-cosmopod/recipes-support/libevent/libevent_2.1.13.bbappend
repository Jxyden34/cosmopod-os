# NVD's CPE has no version ranges for these advisories. The upstream
# 2.1.13 release includes the fixes; keep this evidence scoped to 2.1.13.
# https://github.com/libevent/libevent/releases/tag/release-2.1.13-stable
CVE_STATUS[CVE-2026-63381] = "fixed-version: fixed in libevent 2.1.13 (GHSA-c2pj-cg4r-88c8)"
CVE_STATUS[CVE-2026-63382] = "fixed-version: fixed in libevent 2.1.13 (GHSA-q39v-w2g7-gr8j)"
CVE_STATUS[CVE-2026-63383] = "fixed-version: fixed in libevent 2.1.13 (GHSA-fj29-64w6-73h6)"
CVE_STATUS[CVE-2026-63384] = "fixed-version: fixed in libevent 2.1.13 (GHSA-45c6-qx49-89m8)"
CVE_STATUS[CVE-2026-63387] = "fixed-version: fixed in libevent 2.1.13 (GHSA-58rx-7448-jw47)"
CVE_STATUS[CVE-2026-63388] = "fixed-version: fixed in libevent 2.1.13 (GHSA-cvq5-vrvr-j338)"

# WebSocket support, including the vulnerable fragmented-frame path, was
# introduced only in the 2.2 alpha series.
# https://github.com/libevent/libevent/security/advisories/GHSA-qx89-wf2v-vgmx
CVE_STATUS[CVE-2026-63495] = "not-applicable-config: WebSocket support is absent from the 2.1 series"
