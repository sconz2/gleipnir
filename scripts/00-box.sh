#!/usr/bin/env bash
# Gleipnir: the base box's own admin account, dealt with before anything else.
#
# Vagrant boxes come with a "vagrant" user whose password is "vagrant" and who has sudo
# without a password: that's how Vagrant logs in and provisions. Left as it is, anyone with
# a shell in the machine (claude included) could run "su vagrant", type "vagrant", and be
# root. So its password is locked (Vagrant logs in with a key, which still works, and so
# does its sudo), and sshd stops taking passwords from anyone. On a VPS there's no vagrant
# user, and sshd is left to you (you may be logging in with a password), so this only looks
# for the same kind of hole and says so.
#
# And su itself is kept for admins: only root and the sudo group may use it, so no account
# in the machine can sit trying passwords against another, whatever the passwords are.
set -euo pipefail
source "$GLEIPNIR_SRC/scripts/lib.sh"
export LC_ALL=C   # the messages below are matched in English

SSHD_DROPIN=/etc/ssh/sshd_config.d/00-gleipnir.conf
PAM_SU=/etc/pam.d/su

if id vagrant >/dev/null 2>&1; then
  passwd -l vagrant >/dev/null
  log "The box's vagrant account: password locked (Vagrant logs in with its key)"

  # Keys only over SSH. Named to sort first: sshd takes the first setting it finds.
  if command -v sshd >/dev/null; then
    install -d -m 0755 "$(dirname "$SSHD_DROPIN")"
    printf '# Managed by Gleipnir: keys only, no passwords\nPasswordAuthentication no\nKbdInteractiveAuthentication no\n' > "$SSHD_DROPIN"
    chmod 0644 "$SSHD_DROPIN"
    if sshd -t 2>/dev/null; then
      if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null \
          || warn "sshd didn't reload, so it still takes passwords until it's restarted: sudo systemctl restart ssh"
      else
        log "sshd isn't running now; it takes keys only from when it starts"
      fi
    else
      rm -f "$SSHD_DROPIN"
      fail "sshd didn't accept Gleipnir's settings (sshd -t); nothing was changed"
    fi
  else
    warn "sshd isn't installed, so there was nothing to set to keys only"
  fi
fi

# su for admins only (root and the sudo group), refused before any password is asked for
if [ -f "$PAM_SU" ]; then
  if ! grep -Eq '^[[:space:]]*auth[[:space:]]+(required|requisite)[[:space:]]+pam_wheel\.so' "$PAM_SU"; then
    sed -i '/^auth[[:space:]]\+sufficient[[:space:]]\+pam_rootok\.so/a # Gleipnir: only root and the sudo group may use su\nauth       requisite  pam_wheel.so use_uid group=sudo' "$PAM_SU"
  fi
  if grep -Eq '^[[:space:]]*auth[[:space:]]+(required|requisite)[[:space:]]+pam_wheel\.so' "$PAM_SU"; then
    log "su: for root and the sudo group only"
  else
    warn "$PAM_SU doesn't look as expected, so su wasn't restricted to admins; add: auth requisite pam_wheel.so use_uid group=sudo"
  fi
else
  warn "$PAM_SU isn't there, so su wasn't restricted to admins"
fi

# Any account that can use sudo and also has a password is a way to root for whoever can
# guess the password. In a Vagrant VM there must be none left; on a VPS it may be your
# own admin account, which is yours to decide about.
open_accounts=()
while IFS=: read -r user _ uid _; do
  [ "$uid" -eq 0 ] || [ "$uid" -ge 1000 ] || continue
  [ "$user" = nobody ] && continue
  sudo -n -l -U "$user" 2>/dev/null | grep -q 'is not allowed to run sudo' && continue
  [ "$(passwd -S "$user" 2>/dev/null | awk '{ print $2 }')" = P ] || continue
  open_accounts+=("$user")
done < /etc/passwd
if [ "${#open_accounts[@]}" -gt 0 ]; then
  if id vagrant >/dev/null 2>&1; then
    fail "these accounts can use sudo and have a password, so anyone in the machine could try to become root: ${open_accounts[*]}"
  else
    warn "these accounts can use sudo and have a password: ${open_accounts[*]}. Only admins can use su now, but use keys and lock it (passwd -l) if you can."
  fi
fi