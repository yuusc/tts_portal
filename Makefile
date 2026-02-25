# Repositories
LOCAL_TTN_REPO        := git@github.com:yuusc/local_TTN.git
LOCAL_CHIRPSTACK_REPO := yuusc/local_ChirpStack
KAJIMA_BUS_REPO       := yuusc/kajima_bus_webapp

LOCAL_TTN_DIR        := local_TTN
LOCAL_CHIRPSTACK_DIR := local_ChirpStack
KAJIMA_BUS_DIR       := kajima_bus_webapp

# Backend selection: saved in .backend after clone, override with BACKEND=chirpstack
BACKEND_FILE := .backend
-include $(BACKEND_FILE)
BACKEND ?= ttn

ifeq ($(BACKEND),chirpstack)
  LORA_DIR    := $(LOCAL_CHIRPSTACK_DIR)
  LORA_LABEL  := ChirpStack
  LORA_UP     := docker compose -f $(LOCAL_CHIRPSTACK_DIR)/docker-compose.yml up -d
  LORA_DOWN   := docker compose -f $(LOCAL_CHIRPSTACK_DIR)/docker-compose.yml down
  LORA_STATUS := docker compose -f $(LOCAL_CHIRPSTACK_DIR)/docker-compose.yml ps
else
  LORA_DIR    := $(LOCAL_TTN_DIR)
  LORA_LABEL  := TTN Stack
  LORA_UP     := $(MAKE) -C $(LOCAL_TTN_DIR) up
  LORA_DOWN   := $(MAKE) -C $(LOCAL_TTN_DIR) down
  LORA_STATUS := $(MAKE) -C $(LOCAL_TTN_DIR) status
endif

# Paths (absolute)
ROOT_DIR       := $(shell pwd)
KAJIMA_BUS_ABS := $(ROOT_DIR)/$(KAJIMA_BUS_DIR)
KAJIMA_BIN     := kajima_bus_app
SERVICE_NAME   := kajima-bus-webapp

# Architecture: amd64 or arm64 (auto-detected, override with ARCH=arm64)
ARCH ?= $(shell uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
KAJIMA_ZIP_PATTERN := $(KAJIMA_BIN)_*_linux_$(ARCH).zip

# Portal
PORTAL_DIR     := $(ROOT_DIR)/portal
PORTAL_SERVICE := portal

# Host IP address (auto-detected)
HOST_IP := $(shell hostname -I | awk '{print $$1}')

# tiles.zip: opt-in download (default: off)
# Usage: make TILES=1 clone
TILES ?= 0

define download_tiles
	@if [ "$(TILES)" = "1" ]; then \
		echo ">>> tiles.zip をダウンロード中..."; \
		mkdir -p $(KAJIMA_BUS_DIR)/static/tiles; \
		gh release download --repo $(KAJIMA_BUS_REPO) --pattern 'tiles.zip' -D $(KAJIMA_BUS_DIR) --clobber; \
		mv $(KAJIMA_BUS_DIR)/tiles.zip $(KAJIMA_BUS_DIR)/static/tiles/tiles.zip; \
		cd $(KAJIMA_BUS_DIR)/static/tiles && unzip -o tiles.zip && rm -f tiles.zip; \
		echo ">>> tiles を static/ に展開しました。"; \
	fi
endef

.PHONY: all clone build clean local_ttn local_chirpstack loraserver kajima_bus copy-certs pull \
        start stop restart status install-service uninstall-service \
        install-portal-service uninstall-portal-service \
        check-gh check-docker download-webapp update-webapp help
.DEFAULT_GOAL := help

help:
	@echo ""
	@echo "使い方: make [ターゲット] [BACKEND=ttn|chirpstack] [ARCH=amd64|arm64]"
	@echo ""
	@echo "  BACKEND=ttn         TTN (The Things Network) を使用 (デフォルト)"
	@echo "  BACKEND=chirpstack  ChirpStack を使用"
	@echo "  ARCH=amd64          x86_64 向けバイナリを使用 (デフォルト: 自動検出)"
	@echo "  ARCH=arm64          ARM64 向けバイナリを使用"
	@echo ""
	@echo "現在の設定:"
	@echo "  BACKEND    = $(BACKEND)"
	@echo "  LORA_DIR   = $(LORA_DIR)"
	@echo "  ARCH       = $(ARCH)"
	@echo "  ZIP        = $(KAJIMA_ZIP_PATTERN)"
	@echo "  TILES      = $(TILES)  (1: tiles.zip もダウンロード、0: スキップ)"
	@echo ""
	@echo "主要ターゲット:"
	@echo "  all           クローン・ビルド・起動をまとめて実行"
	@echo "  clone         リポジトリのクローンとバイナリのダウンロード"
	@echo "  build         LoRaサーバーと Webアプリのビルド"
	@echo "  start         全サービスを起動"
	@echo "  stop          全サービスを停止"
	@echo "  restart       全サービスを再起動"
	@echo "  status        全サービスのステータスを表示"
	@echo "  pull          リポジトリとバイナリを最新に更新"
	@echo "  update-webapp Webアプリバイナリのみ最新に更新"
	@echo "  clean         全サービス停止・systemd解除・ディレクトリ削除"
	@echo ""
	@echo "例:"
	@echo "  make all                              # TTN + 自動検出アーキテクチャで全セットアップ"
	@echo "  make ARCH=arm64 all                   # ARM64向けバイナリで全セットアップ"
	@echo "  make BACKEND=chirpstack all           # ChirpStackで全セットアップ"
	@echo "  make BACKEND=chirpstack ARCH=arm64 all"
	@echo "  make update-webapp                    # Webアプリのみ最新化"
	@echo "  make TILES=1 clone                    # tiles.zip も含めてダウンロード"
	@echo "  make TILES=1 update-webapp            # tiles.zip も含めて更新"
	@echo ""

all: clone build start

# ===== Prerequisites =====
check-docker:
	@# 1) docker がインストールされているか
	@command -v docker >/dev/null 2>&1 || { \
		echo ""; \
		echo "=== Error: docker が見つかりません ==="; \
		echo ""; \
		echo "  インストール方法:"; \
		echo "    https://docs.docker.com/engine/install/"; \
		echo ""; \
		exit 1; \
	}
	@# 2) docker compose が使えるか
	@docker compose version >/dev/null 2>&1 || { \
		echo ""; \
		echo "=== Error: docker compose が見つかりません ==="; \
		echo ""; \
		echo "  Docker Compose V2 が必要です。"; \
		echo "  インストール方法:"; \
		echo "    https://docs.docker.com/compose/install/"; \
		echo ""; \
		exit 1; \
	}
	@# 3) docker デーモンが起動しているか
	@docker info >/dev/null 2>&1 || { \
		echo ""; \
		echo "=== Error: docker デーモンに接続できません ==="; \
		echo ""; \
		echo "  以下を確認してください:"; \
		echo "    1. Docker デーモンが起動しているか"; \
		echo "       起動: sudo systemctl start docker"; \
		echo "    2. 現在のユーザーが docker グループに所属しているか"; \
		echo "       追加: sudo usermod -aG docker $$USER"; \
		echo "       (反映にはログアウト/ログインが必要)"; \
		echo ""; \
		exit 1; \
	}

check-gh:
	@# 1) gh CLI がインストールされているか
	@command -v gh >/dev/null 2>&1 || { \
		echo ""; \
		echo "=== Error: gh (GitHub CLI) が見つかりません ==="; \
		echo ""; \
		echo "  インストール方法:"; \
		echo "    Ubuntu/Debian : sudo apt install gh"; \
		echo "    その他        : https://cli.github.com/"; \
		echo ""; \
		echo "  インストール後、以下を実行してログインしてください:"; \
		echo "    gh auth login"; \
		echo ""; \
		exit 1; \
	}
	@# 2) gh にログイン済みか
	@gh auth status >/dev/null 2>&1 || { \
		echo ""; \
		echo "=== Error: gh にログインしていません ==="; \
		echo ""; \
		echo "  以下のコマンドでログインしてください:"; \
		echo "    gh auth login"; \
		echo ""; \
		echo "  プライベートリポジトリにアクセスするには、"; \
		echo "  認証時に 'repo' スコープを付与してください。"; \
		echo ""; \
		exit 1; \
	}
	@# 3) リポジトリにアクセスできるか
	@gh api repos/$(KAJIMA_BUS_REPO) --jq '.full_name' >/dev/null 2>&1 || { \
		echo ""; \
		echo "=== Error: リポジトリ $(KAJIMA_BUS_REPO) にアクセスできません ==="; \
		echo ""; \
		echo "  以下を確認してください:"; \
		echo "    1. リポジトリ名が正しいか (現在: $(KAJIMA_BUS_REPO))"; \
		echo "    2. リポジトリが GitHub 上に存在するか"; \
		echo "    3. ログイン中のアカウントにアクセス権限があるか"; \
		echo "       確認: gh auth status"; \
		echo "    4. トークンに 'repo' スコープが付与されているか"; \
		echo "       (プライベートリポジトリの場合は必須)"; \
		echo "       スコープ不足の場合: gh auth refresh -s repo"; \
		echo ""; \
		exit 1; \
	}
	@# 4) リリースが存在するか
	@gh release view --repo $(KAJIMA_BUS_REPO) --json tagName --jq '.tagName' >/dev/null 2>&1 || { \
		echo ""; \
		echo "=== Error: リポジトリ $(KAJIMA_BUS_REPO) にリリースが見つかりません ==="; \
		echo ""; \
		echo "  以下を確認してください:"; \
		echo "    1. リポジトリにリリースが作成されているか"; \
		echo "       確認: gh release list --repo $(KAJIMA_BUS_REPO)"; \
		echo "    2. リリースに 'kajima_bus_app_*_linux_$(ARCH).zip' がアップロードされているか"; \
		echo ""; \
		exit 1; \
	}

# ===== Clone / Download =====
clone: $(LORA_DIR) $(KAJIMA_BUS_DIR)/$(KAJIMA_BIN)

$(LOCAL_TTN_DIR):
	git clone $(LOCAL_TTN_REPO)
	@echo "BACKEND := ttn" > $(BACKEND_FILE)
	@echo "var BACKEND = 'ttn';" > $(PORTAL_DIR)/config.js

$(LOCAL_CHIRPSTACK_DIR): check-gh
	@[ -d $@ ] || gh repo clone $(LOCAL_CHIRPSTACK_REPO)
	@echo "BACKEND := chirpstack" > $(BACKEND_FILE)
	@echo "var BACKEND = 'chirpstack';" > $(PORTAL_DIR)/config.js

$(KAJIMA_BUS_DIR)/$(KAJIMA_BIN): check-gh
	mkdir -p $(KAJIMA_BUS_DIR)
	gh release download --repo $(KAJIMA_BUS_REPO) --pattern '$(KAJIMA_ZIP_PATTERN)' -D $(KAJIMA_BUS_DIR) --clobber
	cd $(KAJIMA_BUS_DIR) && unzip -o $(KAJIMA_ZIP_PATTERN) && rm -f $(KAJIMA_ZIP_PATTERN)
	chmod +x $(KAJIMA_BUS_DIR)/$(KAJIMA_BIN)
	$(download_tiles)

# ===== Build =====
build: loraserver kajima_bus

local_ttn: check-docker $(LOCAL_TTN_DIR)
	$(MAKE) -C $(LOCAL_TTN_DIR) init

local_chirpstack: check-docker $(LOCAL_CHIRPSTACK_DIR)
	@echo ">>> ChirpStack: クローン済み。docker compose up で起動します。"

loraserver:
ifeq ($(BACKEND),chirpstack)
	$(MAKE) local_chirpstack
else
	$(MAKE) local_ttn
endif

copy-certs: loraserver
ifeq ($(BACKEND),chirpstack)
	@echo ">>> ChirpStack: 自己署名証明書を生成します..."
	openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
		-keyout $(KAJIMA_BUS_DIR)/key.pem \
		-out $(KAJIMA_BUS_DIR)/cert.pem \
		-subj "/CN=localhost"
	@echo ">>> cert.pem / key.pem を生成しました。"
else
	cp $(LOCAL_TTN_DIR)/certs/cert.pem $(KAJIMA_BUS_DIR)/cert.pem
	cp $(LOCAL_TTN_DIR)/certs/key.pem $(KAJIMA_BUS_DIR)/key.pem
endif

kajima_bus: $(KAJIMA_BUS_DIR)/$(KAJIMA_BIN) copy-certs

# ===== Start / Stop =====
start: check-docker install-service install-portal-service
	@[ -d $(LORA_DIR) ] || { \
		echo ""; \
		echo "=== Error: $(LORA_DIR) が見つかりません ==="; \
		echo ""; \
		echo "  先に以下を実行してください:"; \
		echo "    make clone  (BACKEND=$(BACKEND) の場合)"; \
		echo ""; \
		exit 1; \
	}
	$(LORA_UP)
	sudo systemctl start $(SERVICE_NAME)
	sudo systemctl start $(PORTAL_SERVICE)
	@echo ""
	@echo "============================================"
	@echo " サービス一覧"
	@echo "============================================"
	@echo " [Portal]"
	@echo "   http://$(HOST_IP):8000"
	@echo ""
	@echo " [Kajima Bus Webapp]"
	@echo "   https://$(HOST_IP):8443"
	@echo ""
ifeq ($(BACKEND),chirpstack)
	@echo " [ChirpStack]"
	@echo "   UI          : http://$(HOST_IP):8080"
	@echo "   REST API    : http://$(HOST_IP):8090"
	@echo "   Grafana     : http://$(HOST_IP):3000"
	@echo "   Prometheus  : http://$(HOST_IP):9090"
	@echo "   MQTT        : $(HOST_IP):1883"
	@echo "   GW Bridge (UDP)         : $(HOST_IP):1700/udp"
	@echo "   GW Bridge (HTTP)        : $(HOST_IP):8070"
	@echo "   GW Bridge (BasicStation): $(HOST_IP):3001"
else
	@echo " [TTN Stack]"
	@echo "   詳細: make -C $(LOCAL_TTN_DIR) logs"
endif
	@echo "============================================"
	@echo ""
	@echo " ログ確認:"
	@echo "   Webapp : sudo journalctl -u $(SERVICE_NAME) -f"
	@echo "   Portal : sudo journalctl -u $(PORTAL_SERVICE) -f"
	@echo "============================================"
	@echo ""

stop:
	sudo systemctl stop $(PORTAL_SERVICE) || true
	sudo systemctl stop $(SERVICE_NAME) || true
	@[ -d $(LORA_DIR) ] && $(LORA_DOWN) || true

restart: stop start

status:
	@[ -d $(LORA_DIR) ] && $(LORA_STATUS) || true
	@echo ""
	sudo systemctl status $(SERVICE_NAME) --no-pager
	@echo ""
	sudo systemctl status $(PORTAL_SERVICE) --no-pager

# ===== systemd =====
install-service:
	@echo ">>> Installing systemd service: $(SERVICE_NAME)"
	@printf '%s\n' \
		'[Unit]' \
		'Description=Kajima Bus Web Application' \
		'After=network.target docker.service' \
		'' \
		'[Service]' \
		'Type=simple' \
		'WorkingDirectory=$(KAJIMA_BUS_ABS)' \
		'ExecStart=$(KAJIMA_BUS_ABS)/$(KAJIMA_BIN)' \
		'Restart=on-failure' \
		'RestartSec=5' \
		'' \
		'[Install]' \
		'WantedBy=multi-user.target' \
		| sudo tee /etc/systemd/system/$(SERVICE_NAME).service > /dev/null
	sudo systemctl daemon-reload
	sudo systemctl enable $(SERVICE_NAME)
	@echo ">>> $(SERVICE_NAME) installed and enabled."

uninstall-service:
	sudo systemctl stop $(SERVICE_NAME) || true
	sudo systemctl disable $(SERVICE_NAME) || true
	sudo rm -f /etc/systemd/system/$(SERVICE_NAME).service
	sudo systemctl daemon-reload
	@echo ">>> $(SERVICE_NAME) removed."

# ===== Portal systemd =====
install-portal-service:
	@echo ">>> Installing systemd service: $(PORTAL_SERVICE)"
	@printf '%s\n' \
		'[Unit]' \
		'Description=Service Portal (HTTP)' \
		'After=network.target' \
		'' \
		'[Service]' \
		'Type=simple' \
		'WorkingDirectory=$(PORTAL_DIR)' \
		'ExecStart=/usr/bin/python3 -m http.server 8000' \
		'Restart=on-failure' \
		'RestartSec=5' \
		'' \
		'[Install]' \
		'WantedBy=multi-user.target' \
		| sudo tee /etc/systemd/system/$(PORTAL_SERVICE).service > /dev/null
	sudo systemctl daemon-reload
	sudo systemctl enable $(PORTAL_SERVICE)
	@echo ">>> $(PORTAL_SERVICE) installed and enabled."

uninstall-portal-service:
	sudo systemctl stop $(PORTAL_SERVICE) || true
	sudo systemctl disable $(PORTAL_SERVICE) || true
	sudo rm -f /etc/systemd/system/$(PORTAL_SERVICE).service
	sudo systemctl daemon-reload
	@echo ">>> $(PORTAL_SERVICE) removed."

# ===== Update webapp binary =====
update-webapp: check-gh
	gh release download --repo $(KAJIMA_BUS_REPO) --pattern '$(KAJIMA_ZIP_PATTERN)' -D $(KAJIMA_BUS_DIR) --clobber
	cd $(KAJIMA_BUS_DIR) && unzip -o $(KAJIMA_ZIP_PATTERN) && rm -f $(KAJIMA_ZIP_PATTERN)
	chmod +x $(KAJIMA_BUS_DIR)/$(KAJIMA_BIN)
	$(download_tiles)
	@echo ">>> $(KAJIMA_BIN) ($(ARCH)) updated to latest release."

# ===== Pull =====
pull: $(LORA_DIR) check-gh
	cd $(LORA_DIR) && git pull
	gh release download --repo $(KAJIMA_BUS_REPO) --pattern '$(KAJIMA_ZIP_PATTERN)' -D $(KAJIMA_BUS_DIR) --clobber
	cd $(KAJIMA_BUS_DIR) && unzip -o $(KAJIMA_ZIP_PATTERN) && rm -f $(KAJIMA_ZIP_PATTERN)
	chmod +x $(KAJIMA_BUS_DIR)/$(KAJIMA_BIN)
	$(download_tiles)
	@echo ">>> $(KAJIMA_BIN) ($(ARCH)) updated to latest release."

# ===== Clean =====
clean: stop uninstall-service uninstall-portal-service
	@[ -d $(LOCAL_TTN_DIR) ] && $(MAKE) -C $(LOCAL_TTN_DIR) clean || true
	@[ -d $(LOCAL_CHIRPSTACK_DIR) ] && $(MAKE) -C $(LOCAL_CHIRPSTACK_DIR) clean || true
	sudo rm -rf $(LOCAL_TTN_DIR) $(LOCAL_CHIRPSTACK_DIR) $(KAJIMA_BUS_DIR)
	rm -f $(BACKEND_FILE)
