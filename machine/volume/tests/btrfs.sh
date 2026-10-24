#!/bin/sh
# A btrfs for tests, a subvolume a directory marked so and its id a checksum of its path, what it
# was asked written to `asked` beside it, and its qgroups and their members kept there too. A
# subvolume deleted is moved beside it, which the test removes with the rest.
d=$(dirname "$0")
echo "$@" >>"$d/asked"
case "$1 $2" in
"subvolume create") mkdir "$3" && touch "$3/.subvolume" ;;
"subvolume delete") mv "$4" "$(mktemp -d "$d/deleted.XXXXXX")" ;;
"subvolume sync") ;;
"inspect-internal rootid")
	p=$3
	while [ ! -e "$p/.subvolume" ] && [ "$p" != / ]; do p=$(dirname "$p"); done
	[ "$p" != / ] || {
		echo "ERROR: not a btrfs filesystem: $3" >&2
		exit 1
	}
	printf '%s' "$p" | cksum | cut -d' ' -f1
	;;
"qgroup create")
	if grep -qx "$3" "$d/qgroups" 2>/dev/null; then
		echo "ERROR: unable to create quota group: File exists" >&2
		exit 1
	fi
	echo "$3" >>"$d/qgroups"
	;;
"qgroup assign")
	if grep -qx "$3 $4" "$d/members" 2>/dev/null; then
		echo "ERROR: unable to assign quota group: File exists" >&2
		exit 1
	fi
	echo "$3 $4" >>"$d/members"
	;;
"qgroup destroy")
	if ! grep -qx "$3" "$d/qgroups" 2>/dev/null; then
		echo "ERROR: unable to destroy quota group: No such file or directory" >&2
		exit 1
	fi
	grep -vx "$3" "$d/qgroups" >"$d/qgroups.new"
	mv "$d/qgroups.new" "$d/qgroups"
	;;
esac
