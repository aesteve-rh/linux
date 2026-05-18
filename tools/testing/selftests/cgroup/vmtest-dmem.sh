#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Copyright (c) 2026 Red Hat, Inc.
#
# Run cgroup test_dmem inside a virtme-ng VM.
# Dependencies:
#		* virtme-ng
#		* qemu	(used by virtme-ng)

set -euo pipefail

readonly SCRIPT_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly KERNEL_CHECKOUT="$(realpath "${SCRIPT_DIR}"/../../../../)"

source "${SCRIPT_DIR}"/../kselftest/ktap_helpers.sh

QEMU="qemu-system-$(uname -m)"
VERBOSE=0
SHELL_MODE=0
VM_SCRIPT=""

function usage() {
	cat <<EOF
$0 [OPTIONS]
Options:
	-q	QEMU binary/path (default: ${QEMU})
	-s	Start interactive shell in VM instead of running tests
	-v	Verbose output (vng boot logs on stdout)
	-h	Display this help
EOF
}

function cleanup() {
	rm -f "${VM_SCRIPT}"
}
trap cleanup EXIT

function skip() {
	local msg=${1:-""}

	echo "SKIP: ${msg}" >&2
	exit "${KSFT_SKIP}"
}

function fail() {
	local msg=${1:-""}

	echo "FAIL: ${msg}" >&2
	exit "${KSFT_FAIL}"
}

function check_deps() {
	for dep in vng "${QEMU}"; do
		if ! command -v "${dep}" >/dev/null 2>&1; then
			skip "dependency ${dep} not found"
		fi
	done
}

# Run vng with common flags. Extra arguments are appended by the caller:
#   --exec <script>  for automated test runs
#   (nothing)        for interactive shell mode
function run_vm() {
	local verbose_opt=""

	[[ "${VERBOSE}" -eq 1 ]] && verbose_opt="--verbose"

	vng \
		--run \
		${verbose_opt:+"${verbose_opt}"} \
		--qemu="$(command -v "${QEMU}")" \
		--user root \
		--rw \
		"$@"
}

function main() {
	while getopts ':hvq:s' opt; do
		case "${opt}" in
		v) VERBOSE=1 ;;
		q) QEMU="${OPTARG}" ;;
		s) SHELL_MODE=1 ;;
		h) usage; exit 0 ;;
		*) usage; exit 1 ;;
		esac
	done

	check_deps

	if [[ "${SHELL_MODE}" -eq 1 ]]; then
		echo "Starting interactive shell in VM. Exit to stop VM."
		run_vm
		exit 0
	fi

	# Write the VM-side script into the script directory so it is
	# accessible in the guest via the --rw host filesystem mount.
	VM_SCRIPT="$(mktemp --suffix=.sh "${SCRIPT_DIR}/.dmem_vmtest_XXXX")"

	cat > "${VM_SCRIPT}" << EOF
#!/bin/bash
set -euo pipefail

mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug

# Verify cgroup controllers are available.
if ! grep -q dmem /sys/fs/cgroup/cgroup.controllers || \
   ! grep -q memory /sys/fs/cgroup/cgroup.controllers; then
	echo "guest kernel missing CONFIG_CGROUP_DMEM or CONFIG_MEMCG" >&2
	exit 4
fi

# Load dmem_selftest: try built-in first, then modprobe.
if [[ -e /sys/kernel/debug/dmem_selftest/charge ]]; then
	echo "dmem_selftest ready (built-in or already loaded)"
elif modprobe -q dmem_selftest 2>/dev/null && \
     [[ -e /sys/kernel/debug/dmem_selftest/charge ]]; then
	echo "dmem_selftest ready (modprobe)"
else
	echo "dmem_selftest unavailable" >&2
	exit 4
fi

echo "Running cgroup/test_dmem in VM..."
"${SCRIPT_DIR}/test_dmem"
EOF

	echo "Booting virtme-ng VM..."
	run_vm --exec "bash ${VM_SCRIPT}"
}

main "$@"
