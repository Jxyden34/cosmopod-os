# Local release secrets

Private signing material must not live here. This directory contains only this
policy marker so accidental local secrets remain ignored by Git.

Generate a key pair with
`scripts/generate-signing-key.sh --replace-device-key`. The default private-key
location is `~/.config/cosmopod-os/keys`, outside the repository and OneDrive.
This initializes once and refuses to overwrite an existing pair; production
rotation requires a separately tested overlapping-trust migration.
Keep production keys offline or in a KMS/HSM. Only the public verification key
is copied into the OS layer.
