CC = ccache clang
JOBS ?= 16

LINUX_SRC ?= kernel/linux
FREEBSD_SRC ?= kernel/freebsd
FREEBSD_CONFIG ?= config/freebsd/freebsd.config
FREEBSD_IMAGE ?= image/freebsd/freebsd.qcow2
FREEBSD_DEV_IMAGE ?= $(if $(wildcard image/freebsd/dev.qcow2),image/freebsd/dev.qcow2,$(FREEBSD_IMAGE))
FREEBSD_SSHKEY ?= image/freebsd/freebsd.id_rsa
FREEBSD_OVERLAY ?=
ASTERINAS_SRC ?= kernel/asterinas
ASTERINAS_CONFIG ?= config/asterinas/asterinas.toml
ASTERINAS_IMAGE ?= image/asterinas/asterinas.img
ASTERINAS_SSHKEY ?= image/asterinas/asterinas.id_rsa
ASTERINAS_OVERLAY ?=

.PHONY: syzutils syzutils-linux syzutils-freebsd syzutils-asterinas linux freebsd freebsd-install asterinas asterinas-install cleanrepro

syzutils: syzutils-linux

syzutils-linux:
	$(MAKE) -C syzkaller generate execprog executor symbolize crush -j8

syzutils-asterinas:
	$(MAKE) -C syzkaller generate execprog executor crush -j8

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

asterinas:
	bash scripts/asterinas/build.sh \
		-s $(ASTERINAS_SRC) \
		-c $(ASTERINAS_CONFIG) \
		-j $(JOBS)

asterinas-install:
	bash scripts/asterinas/install-kernel.sh \
		-i $(ASTERINAS_IMAGE) \
		-k $(ASTERINAS_SRC) \
		$(if $(ASTERINAS_OVERLAY),-o $(ASTERINAS_OVERLAY))

cleanrepro:
	rm -rf repro/symbolize repro/*.log repro/report repro/repro.c repro/repro.syz repro/crashes repro/instance-*
