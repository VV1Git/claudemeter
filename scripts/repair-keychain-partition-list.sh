#!/bin/sh
#
# Restores the list of programs allowed to read Claude Code's credential item.
#
# macOS keeps a "partition list" on each Keychain item naming the code identities that may read
# it without a password prompt. Writing an item's data resets that list around whoever wrote it,
# so a token written by `claude` evicts ClaudeMeter, and a token written by anything else evicts
# `apple-tool:` — after which every `claude` command raises a password dialog, one the CLI itself
# tears down after two seconds, which is why clicking "Always Allow" never settles it. This puts
# both identities back in one go.
#
# ClaudeMeter no longer writes that item at all, so it cannot cause the `claude`-side lockout any
# more; this script is for undoing damage left by a version that did. For the other direction —
# ClaudeMeter evicted by a `claude` token write — you do not need this: the app notices, declines
# to raise a dialog on its own, and offers an "Authorize…" button in the panel instead.
#
# ClaudeMeter's identity comes from how it was signed, so it is not the same string on every
# machine. The default below is this project's team. If you built your own copy with a different
# certificate, or ad-hoc, pass the right one:
#
#     codesign -dv --verbose=4 /Applications/ClaudeMeter.app 2>&1 | grep TeamIdentifier
#     APP_IDENTITY=teamid:XXXXXXXXXX ./scripts/repair-keychain-partition-list.sh
#
# An ad-hoc build has no team and reads under `cdhash:<hex>`; ClaudeMeter's own Settings window
# offers the exact line for the copy you are running, which is the easier route.
#
# What it will not do: read the credential, write the credential, delete anything, take a
# password on the command line, drop an identity that is on the list already, or touch any item
# other than the one named below. `security` asks for the login password itself, through the
# terminal, where nothing kills it mid-typing.

set -eu

SERVICE="Claude Code-credentials"
ACCOUNT="${USER:-$(id -un)}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
CLI_IDENTITY="apple-tool:"
APP_IDENTITY="${APP_IDENTITY:-teamid:7DJSY2AKJK}"

# Attributes and ACLs only. There is no `-d` here and there must never be one: `-d` decrypts
# every item in the keychain, which is the dialog storm this script exists to end.
#
# The awk resets at every `class:` line and stops at the first one after the item was found, so
# an item that carries no partition entry reports nothing rather than walking on and printing a
# neighbouring item's list as though it were this one.
partition_list() {
	/usr/bin/security dump-keychain -a "$KEYCHAIN" 2>/dev/null | awk '
		/^class: / { if (found) exit; found = 0; inside = 0 }
		/"svce"<blob>="'"$SERVICE"'"$/ { found = 1 }
		found && /partition_id/ { inside = 1; next }
		inside && /description:/ { sub(/^[ \t]*description: */, ""); print; exit }
	'
}

if [ ! -f "$KEYCHAIN" ]; then
	echo "No login keychain at $KEYCHAIN." >&2
	exit 1
fi

# Exact match, so a mistyped service name fails here rather than editing a neighbouring item —
# the login keychain holds a good many items whose service names begin the same way.
if ! /usr/bin/security find-generic-password -s "$SERVICE" -a "$ACCOUNT" "$KEYCHAIN" >/dev/null 2>&1
then
	echo "No item with service \"$SERVICE\" and account \"$ACCOUNT\" in $KEYCHAIN." >&2
	echo "Sign in with \`claude\` first; there is nothing here to repair." >&2
	exit 1
fi

BEFORE=$(partition_list)

# `-S` replaces the whole list, so a run that cannot see what is on it now would be replacing
# something unknown with two identities and silently dropping the rest. Refuse instead.
if [ -z "$BEFORE" ]; then
	echo "Could not read the item's current partition list." >&2
	echo "Refusing to replace a list this script cannot see. Check that" >&2
	echo "\`security dump-keychain -a\` prints an \"access:\" block for \"$SERVICE\"." >&2
	exit 1
fi

# The new list is the old one plus whichever of the two required identities is missing, never
# just the two: a third program that has been granted access keeps it.
CURRENT=$(printf '%s' "$BEFORE" | tr -d ' ')
AFTER_LIST="$CURRENT"
MISSING=""
for identity in "$CLI_IDENTITY" "$APP_IDENTITY"; do
	case ",$AFTER_LIST," in
	*",$identity,"*) ;;
	*)
		AFTER_LIST="$AFTER_LIST,$identity"
		MISSING="$MISSING $identity"
		;;
	esac
done

echo "Item:              $SERVICE (account $ACCOUNT)"
echo "Keychain:          $KEYCHAIN"
echo "Partitions now:    $BEFORE"
echo "Partitions after:  $AFTER_LIST"
echo

if [ -z "$MISSING" ]; then
	echo "Both Claude Code ($CLI_IDENTITY) and ClaudeMeter ($APP_IDENTITY) are already"
	echo "admitted, so this would change nothing. Run it anyway only if you are rehearsing."
	echo
else
	echo "Currently missing:$MISSING"
	echo
fi

echo "About to run:"
echo "  /usr/bin/security set-generic-password-partition-list \\"
echo "      -S '$AFTER_LIST' -s '$SERVICE' -a $ACCOUNT \\"
echo "      $KEYCHAIN"
echo
echo "To undo it afterwards:"
echo "  /usr/bin/security set-generic-password-partition-list \\"
echo "      -S '$CURRENT' -s '$SERVICE' -a $ACCOUNT \\"
echo "      $KEYCHAIN"
echo
echo "security will ask for your login password. It is not read, stored or echoed by this"
echo "script — the prompt comes from security itself."
printf "Continue? [y/N] "
read -r REPLY
case "$REPLY" in
y | Y | yes | YES) ;;
*)
	echo "Nothing changed."
	exit 0
	;;
esac

/usr/bin/security set-generic-password-partition-list \
	-S "$AFTER_LIST" \
	-s "$SERVICE" \
	-a "$ACCOUNT" \
	"$KEYCHAIN"

AFTER=$(partition_list)
echo
echo "Partitions now:    ${AFTER:-<could not read>}"
STILL_MISSING=""
for identity in "$CLI_IDENTITY" "$APP_IDENTITY"; do
	case ",$(printf '%s' "$AFTER" | tr -d ' ')," in
	*",$identity,"*) ;;
	*) STILL_MISSING="$STILL_MISSING $identity" ;;
	esac
done

if [ -n "$STILL_MISSING" ]; then
	echo "Still not on the list:$STILL_MISSING. The repair did not take." >&2
	exit 1
fi
echo "Claude Code and ClaudeMeter are both admitted again."
