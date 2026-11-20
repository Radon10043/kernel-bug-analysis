CC = ccache clang
JOBS ?= 16

LINUX_SRC ?= kernel/linux
FREEBSD_SRC ?= kernel/freebsd
FREEBSD_CONFIG ?= $(if $(wildcard issue/freebsd.config),issue/freebsd.config,config/freebsd/freebsd.config)
FREEBSD_IMAGE ?= image/freebsd/freebsd.qcow2
FREEBSD_DEV_IMAGE ?= $(if $(wildcard image/freebsd/dev.qcow2),image/freebsd/dev.qcow2,$(FREEBSD_IMAGE))
FREEBSD_SSHKEY ?= image/freebsd/freebsd.id_rsa
FREEBSD_OVERLAY ?=

.PHONY: syzutils syzutils-linux syzutils-freebsd linux freebsd freebsd-install cleanrepro

syzutils: syzutils-linux

syzutils-linux:
	$(MAKE) -C syzkaller generate execprog executor symbolize crush -j8

syzutils-freebsd:
	$(MAKE) -C syzkaller generate symbolize crush -j8
	python3 scripts/freebsd/build-binary.py \
		-i $(FREEBSD_DEV_IMAGE) \
		-k $(FREEBSD_SSHKEY) \
		--syzkaller syzkaller \
		-j $(JOBS)

linux:
	$(MAKE) -C $(LINUX_SRC) CC="$(CC)" olddefconfig all -j$(JOBS)

freebsd:
	bash scripts/freebsd/build.sh \
		-s $(FREEBSD_SRC) \
		-c $(FREEBSD_CONFIG) \
		-j $(JOBS)

freebsd-install:
	python3 scripts/freebsd/install-kernel.py \
		-i $(FREEBSD_IMAGE) \
		-k $(FREEBSD_SSHKEY) \
		-d $(FREEBSD_SRC)/build/dist \
		$(if $(FREEBSD_OVERLAY),-o $(FREEBSD_OVERLAY))

cleanrepro:
	rm -rf repro/symbolize repro/*.log repro/report repro/repro.c repro/repro.syz repro/crashes repro/instance-*
