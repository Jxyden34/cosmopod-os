Cosmopod OS
============

Useful commands:
  ip address
  nmcli device status
  systemctl status weston sshd
  journalctl -b
  mender-update show-artifact
  cosmopod-update check
  sudo cosmopod-update install
  sudo reboot
  sudo cosmopod-update commit

Updates use signed public releases, not a Mender server. Inspect the running
system after reboot before committing. VM media must be replaced separately.

Project documentation: https://github.com/Jxyden34/cosmopod-os
