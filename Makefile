# Copyright (c) 2026
# SPDX-License-Identifier: Apache-2.0

ROOT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

check perf:
	$(MAKE) -C rtl $@ $(if $(PERF_OUT),PERF_OUT="$(abspath $(PERF_OUT))")

formal-icache:
	$(MAKE) -C formal/icache formal-icache

run scan:
	$(MAKE) -C sim $@ \
	  $(if $(CONFIG),CONFIG="$(abspath $(CONFIG))") \
	  $(if $(RESULT),RESULT="$(abspath $(RESULT))") \
	  $(if $(TRACE),TRACE="$(abspath $(TRACE))") \
	  $(if $(SCAN_DIR),SCAN_DIR="$(abspath $(SCAN_DIR))")

clean:
	rm -rf $(ROOT_DIR)/build

.PHONY: check perf formal-icache run scan clean
