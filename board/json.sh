#!/bin/bash
#
# JSON handling functions
#
# It's expected that $JSON variable will contain the name of json file 
# that is to be processed
################################################################################

# Runs jq with given arguments and output resulting json to stdout
# Example: json_edit_noreplace '.foo = 123'
json_edit_noreplace() {
	[[ -e "$JSON" ]] || {
		die "JSON file '$JSON' not found"
		return 1
	}

	sed 's#//.*##' "$JSON" |	# there are // comments, strip them out
	jq "$@"
}

# Runs jq with given arguments and replaces the original file with result
# Example: json_edit '.foo = 123'
json_edit() {
	local tmp=`mktemp`
	json_edit_noreplace "$@" > "$tmp"
	local ret=$?
	[[ "$ret" == 0 ]] && cat "$tmp" > "$JSON"
	rm "$tmp"
	return $ret
}

# Find item in array.
# Example: json_array_find '.slots' '.id == "foo"'
json_array_find() {
	[[ -e "$JSON" ]] || {
		die "JSON file '$JSON' not found"
		return 1
	}

	jq -e "${1}[] | select($2)" "$JSON"
}

# Append items to array
# Example: json_array_append '.slots' '{id: "foo", type: "bar", name: "baz"}'
json_array_append() {
	local array=$1
	shift
	json_edit "${array} = [${array}[], $(join ", " "$@")]"
}

# Delete matching array items
# Example: json_array_delete '.slots' '.id == "foo"'
json_array_delete() {
	json_edit "${1} = (${1} | map(select(($2) | not)))"
}

# Update matching array items
# Example: json_array_update '.slots' '.id == "foo"' '.module = "bar"'
#	this will set .module to "bar" for array items having .id == "foo"
json_array_update() {
	json_edit "${1} = (${1} | map(if ($2) then ($3) else . end))"
}

