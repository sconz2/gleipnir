# shellcheck shell=bash disable=SC2034  # sourced: its settings are used by the steps
# Gleipnir: the versions it installs, and how each download is checked. Every machine gets
# exactly these, so a provision today installs what one did last month. To update one,
# change it here (with its checksum), try it on a machine with nothing real in it, then
# provision the rest. See "Versions" in README.md.

# The VM's base image (Vagrantfile reads this line too)
BOX_VERSION=202510.26.0

# The browser editor, from its GitHub releases, checked against these SHA-256 sums
CODE_SERVER_VERSION=4.144.0
CODE_SERVER_SHA256_amd64=45f5533b502edac68b7eb09c5cec44fd281f80264af9a87fde0bfb2c5e190615
CODE_SERVER_SHA256_arm64=6baef72b340da08e76e5cf1e9504f657d00e80c8776bdaf86e97c30a80cd48e8

# Composer, from its GitHub releases, checked against this SHA-256 sum
COMPOSER_VERSION=2.11.0
COMPOSER_SHA256=9674f12a2a181100d889ebfd0b4510805b3e94cea57869b14b383753d602599b

# Playwright's browsers when the project doesn't use Playwright yet (otherwise its own version)
PLAYWRIGHT_DEFAULT_VERSION=1.64.1

# Signing keys for the apt repositories, checked by fingerprint before they're trusted.
# (Node.js's major version is the machine's "node" setting; apt checks every package's
# signature against this key.)
NODESOURCE_KEY_FINGERPRINT=6F71F525282841EEDAF851B42F59B5F99B1BE0B4
CLAUDE_CODE_KEY_FINGERPRINT=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE