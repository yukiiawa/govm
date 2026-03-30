#!/usr/bin/env sh
set -eu
trap 'exit_code=$?; if [ "$exit_code" -ne 0 ]; then echo "e2e.sh failed" >&2; fi' EXIT

root_dir="${RUNNER_TEMP:-/tmp}/govm-e2e-root"
rm -rf "${root_dir}"

exe="./zig-out/bin/govm"
list_output="$(${exe} --root "${root_dir}" list --stable-only --tail 5)"
printf '%s\n' "${list_output}"

latest_version="$(printf '%s\n' "${list_output}" | awk 'NF { print $1 }' | tail -n 1)"
oldest_tail_version="$(printf '%s\n' "${list_output}" | awk 'NF { print $1 }' | head -n 1)"

if [ -z "${latest_version}" ] || [ -z "${oldest_tail_version}" ]; then
  echo "failed to resolve versions from list output" >&2
  exit 1
fi

${exe} install "${latest_version}"
${exe} use "${latest_version}"

current_output="$(${exe} current)"
printf '%s\n' "${current_output}"
printf '%s' "${current_output}" | grep "${latest_version}" >/dev/null

which_output="$(${exe} which)"
printf '%s\n' "${which_output}"
printf '%s' "${which_output}" | grep "${latest_version}" >/dev/null
printf '%s' "${which_output}" | grep '/current/' >/dev/null && {
  echo "which should point to the real SDK path, not /current/" >&2
  exit 1
}

if ${exe} remove "${latest_version}"; then
  echo "remove should fail for the current version" >&2
  exit 1
fi

if [ "${oldest_tail_version}" != "${latest_version}" ]; then
  ${exe} install "${oldest_tail_version}"
  ${exe} remove "${oldest_tail_version}"
fi
