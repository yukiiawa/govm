set -e
if not set -q RUNNER_TEMP
    set RUNNER_TEMP /tmp
end

set root_dir (string join "" $RUNNER_TEMP "/govm-e2e-root")
rm -rf $root_dir

set exe ./zig-out/bin/govm
echo "Running fish E2E with root: $root_dir"

set list_output ($exe --root $root_dir list --stable-only --tail 5)
printf '%s\n' $list_output

set versions
for line in $list_output
    set fields (string split -m 1 ' ' (string trim $line))
    set versions $versions $fields[1]
end

if test (count $versions) -lt 1
    echo "failed to resolve versions from list output" >&2
    exit 1
end

set latest_version $versions[-1]
set oldest_tail_version $versions[1]

$exe install $latest_version
$exe use $latest_version

set current_output ($exe current)
printf '%s\n' $current_output
if not string match -q "*$latest_version*" $current_output
    echo "current output did not include expected version" >&2
    exit 1
end

set which_output ($exe which)
printf '%s\n' $which_output
if not string match -q "*$latest_version*" $which_output
    echo "which output did not include expected version" >&2
    exit 1
end
if string match -q "*/current/*" (string replace -a '\' '/' $which_output)
    echo "which should point to the real SDK path, not /current/" >&2
    exit 1
end

if $exe remove $latest_version
    echo "remove should fail for the current version" >&2
    exit 1
end

if test "$oldest_tail_version" != "$latest_version"
    $exe install $oldest_tail_version
    $exe remove $oldest_tail_version
end
