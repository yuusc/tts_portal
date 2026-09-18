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

# ===== ソースビルド (2026-09-18 追加) =====
# 理由: bus-app は SQLite 利用のため CGO 必須で、arm64版リリース資産を作るには
# ビルド側に aarch64-linux-gnu-gcc のクロスツールチェーンが要る。用意されていない
# と arm64 版が存在せずラズパイでの取得に失敗する。また32bit OSでは uname -m が
# armv7l を返し ARCH の変換規則に当てはまらない。現地でソースからビルドすれば
# これらを回避できるため、SOURCE=1 で選べるようにする。
# 未指定 (デフォルト0) の場合は従来通りリリースzipを取得する挙動のまま変わらない。
SOURCE ?= 0
KAJIMA_BUS_SRC_DIR := kajima_bus_webapp-src

# kajima_bus_webapp/bus-app/go.mod が要求する Go バージョンのフォールバック値。
# 実際には $(KAJIMA_BUS_SRC_DIR) クローン後に go.mod から動的に読み取る
# (check-go 参照)。クローン前に check-go 単体を実行した場合などに使われる。
REQUIRED_GO_VERSION := 1.25.6

# 初期管理者の認証情報 (SOURCE=1 のときのみ bus-app 側の `make build` にそのまま
# 渡す。bus-app 側で bcrypt ハッシュ化して ldflags 注入する)。未指定なら何も
# 渡さず、bus-app 側の従来動作 (起動時にランダムパスワードを生成して表示) のまま。
ADMIN_USER ?=
ADMIN_PASS ?=

# check-go で Go を /usr/local/go に導入した場合に備えて PATH に加えておく。
# 未導入 (ディレクトリが存在しない) でも無害。
export PATH := /usr/local/go/bin:$(PATH)

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
        check-gh check-docker check-go download-webapp update-webapp help
.DEFAULT_GOAL := help

help:
	@echo ""
	@echo "使い方: make [ターゲット] [BACKEND=ttn|chirpstack] [ARCH=amd64|arm64] [SOURCE=1] [ADMIN_USER=...] [ADMIN_PASS=...]"
	@echo ""
	@echo "  BACKEND=ttn         TTN (The Things Network) を使用 (デフォルト)"
	@echo "  BACKEND=chirpstack  ChirpStack を使用"
	@echo "  ARCH=amd64          x86_64 向けバイナリを使用 (デフォルト: 自動検出)"
	@echo "  ARCH=arm64          ARM64 向けバイナリを使用"
	@echo "  SOURCE=1            bus-app をリリースzipではなく現地でソースからビルド (デフォルト: 0)"
	@echo "                      arm64版リリース資産が無い場合の回避にもなるため、ラズパイでの設置に推奨"
	@echo "  ADMIN_USER=<name>   SOURCE=1 のとき、初期管理者ユーザー名を指定 (bus-appのmake buildへそのまま渡す)"
	@echo "  ADMIN_PASS=<pass>   SOURCE=1 のとき、初期管理者パスワードを指定 (bus-appのmake buildへそのまま渡す)"
	@echo "                      ※ ADMIN_PASS はシェル履歴や ps コマンドの出力に残ります。取り扱いに注意してください"
	@echo ""
	@echo "現在の設定:"
	@echo "  BACKEND    = $(BACKEND)"
	@echo "  LORA_DIR   = $(LORA_DIR)"
	@echo "  ARCH       = $(ARCH)"
	@echo "  ZIP        = $(KAJIMA_ZIP_PATTERN)"
	@echo "  TILES      = $(TILES)  (1: tiles.zip もダウンロード、0: スキップ)"
	@echo "  SOURCE     = $(SOURCE)  (1: 現地ソースビルド、0: リリースzip取得)"
	@echo ""
	@echo "主要ターゲット:"
	@echo "  all           クローン・ビルド・起動をまとめて実行"
	@echo "  clone         リポジトリのクローンとバイナリのダウンロード (SOURCE=1ならソースを取得してビルド)"
	@echo "  build         LoRaサーバーと Webアプリのビルド"
	@echo "  check-go      Goツールチェインの確認・導入 (SOURCE=1利用時に必要)"
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
	@echo "  make SOURCE=1 BACKEND=chirpstack all  # [ラズパイ推奨] 現地ソースビルドで全セットアップ"
	@echo "  make SOURCE=1 ADMIN_USER=admin ADMIN_PASS=xxxx BACKEND=chirpstack all"
	@echo "                                         # 初期管理者の認証情報を指定してソースビルド"
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

# check-go: SOURCE=1 (現地ソースビルド) 用の Go ツールチェイン確認・導入 (2026-09-18 追加)
# $(KAJIMA_BUS_SRC_DIR)/bus-app/go.mod が要求する Go バージョン (無ければ
# REQUIRED_GO_VERSION にフォールバック) を満たさない場合、go.dev の公式 tarball を
# /usr/local/go に展開する。既存の /usr/local/go があれば削除せずタイムスタンプ付き
# ディレクトリへ退避してから展開する (他ツールが依存している可能性があるため)。
# CGO (mattn/go-sqlite3) のビルドに gcc が必須のため、有無もあわせて確認する。
check-go:
	@GO_MOD="$(KAJIMA_BUS_SRC_DIR)/bus-app/go.mod"; \
	REQ_VER=""; \
	if [ -f "$$GO_MOD" ]; then \
		REQ_VER=$$(awk '/^go [0-9]/{print $$2; exit}' "$$GO_MOD"); \
	fi; \
	if [ -z "$$REQ_VER" ]; then REQ_VER="$(REQUIRED_GO_VERSION)"; fi; \
	CUR_VER=""; \
	if command -v go >/dev/null 2>&1; then \
		CUR_VER=$$(go version 2>/dev/null | sed -n 's/^go version go\([0-9.]*\).*/\1/p'); \
	fi; \
	if [ -n "$$CUR_VER" ] && [ "$$(printf '%s\n%s\n' "$$REQ_VER" "$$CUR_VER" | sort -V | head -n1)" = "$$REQ_VER" ]; then \
		echo ">>> Go $$CUR_VER を使用します (要件: $$REQ_VER 以上)"; \
	else \
		if [ -n "$$CUR_VER" ]; then \
			echo ">>> 既存の Go $$CUR_VER は要件 (go.mod: $$REQ_VER 以上) を満たしません。導入します..."; \
		else \
			echo ">>> Go が見つかりません。Go $$REQ_VER を導入します..."; \
		fi; \
		if [ -d /usr/local/go ]; then \
			BACKUP="/usr/local/go.bak-$$(date +%Y%m%d%H%M%S)"; \
			echo ">>> 既存の /usr/local/go を $$BACKUP に退避します (削除はしません)"; \
			sudo mv /usr/local/go "$$BACKUP" || exit 1; \
		fi; \
		GO_TARBALL="go$${REQ_VER}.linux-$(ARCH).tar.gz"; \
		echo ">>> https://go.dev/dl/$$GO_TARBALL をダウンロード中..."; \
		curl -fsSLO "https://go.dev/dl/$$GO_TARBALL" || { \
			echo ""; \
			echo "=== Error: Go tarball のダウンロードに失敗しました ($$GO_TARBALL) ==="; \
			echo "  https://go.dev/dl/ でファイル名を確認してください。"; \
			echo ""; \
			exit 1; \
		}; \
		sudo tar -C /usr/local -xzf "$$GO_TARBALL" || { \
			rm -f "$$GO_TARBALL"; \
			echo "=== Error: /usr/local への展開に失敗しました ==="; \
			exit 1; \
		}; \
		rm -f "$$GO_TARBALL"; \
		echo ">>> Go $$REQ_VER を /usr/local/go に導入しました。"; \
		echo "    このMakefile実行中は PATH に /usr/local/go/bin を自動で追加しています。"; \
		echo "    対話シェルでも使う場合は ~/.bashrc 等に以下を追記してください:"; \
		echo "      export PATH=\$$PATH:/usr/local/go/bin"; \
	fi; \
	command -v gcc >/dev/null 2>&1 || { \
		echo ""; \
		echo "=== Error: gcc が見つかりません (bus-app は CGO 必須のためビルドできません) ==="; \
		echo ""; \
		echo "  インストール方法:"; \
		echo "    sudo apt install build-essential"; \
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

# kajima_bus_webapp のソース一式 (SOURCE=1 のときのみクローンされる)。
# local_ChirpStack と同じ作法 (gh repo clone、無ければクローン) に合わせている (2026-09-18 追加)。
$(KAJIMA_BUS_SRC_DIR): check-gh
	@[ -d $@ ] || gh repo clone $(KAJIMA_BUS_REPO) $@

# SOURCE=1 のとき、kajima_bus_webapp/bus-app を現地で `make build` してバイナリを
# 作る。ADMIN_USER/ADMIN_PASS が指定されていればそのまま bus-app 側の make に渡し、
# bcrypt ハッシュを ldflags 注入した初期管理者アカウント入りでビルドさせる
# (未指定なら何も渡さず、bus-app 側の従来動作のまま)。
# 生成物の配置は、従来のリリースzip展開先 ($(KAJIMA_BUS_DIR)/$(KAJIMA_BIN) 直下に
# バイナリ、static/ templates/ も同階層) と揃え、install-service が参照する
# WorkingDirectory/ExecStart と食い違わないようにしている (2026-09-18 追加)。
define build_webapp_from_source
	@echo ">>> ソースから $(KAJIMA_BIN) をビルドします (SOURCE=1)"; \
	$(MAKE) -C $(KAJIMA_BUS_SRC_DIR)/bus-app build GOARCH=$(ARCH) $(if $(ADMIN_USER),ADMIN_USER=$(ADMIN_USER)) $(if $(ADMIN_PASS),ADMIN_PASS=$(ADMIN_PASS)) && \
	mkdir -p $(KAJIMA_BUS_DIR)/static $(KAJIMA_BUS_DIR)/templates && \
	cp $(KAJIMA_BUS_SRC_DIR)/bus-app/$(KAJIMA_BIN) $(KAJIMA_BUS_DIR)/$(KAJIMA_BIN) && \
	chmod +x $(KAJIMA_BUS_DIR)/$(KAJIMA_BIN) && \
	cp -r $(KAJIMA_BUS_SRC_DIR)/bus-app/static/. $(KAJIMA_BUS_DIR)/static/ && \
	cp -r $(KAJIMA_BUS_SRC_DIR)/bus-app/templates/. $(KAJIMA_BUS_DIR)/templates/ && \
	echo ">>> ソースビルド完了: $(KAJIMA_BUS_DIR)/$(KAJIMA_BIN)"
	$(download_tiles)
endef

ifeq ($(SOURCE),1)
$(KAJIMA_BUS_DIR)/$(KAJIMA_BIN): $(KAJIMA_BUS_SRC_DIR) check-go
	$(build_webapp_from_source)
else
$(KAJIMA_BUS_DIR)/$(KAJIMA_BIN): check-gh
	mkdir -p $(KAJIMA_BUS_DIR)
	gh release download --repo $(KAJIMA_BUS_REPO) --pattern '$(KAJIMA_ZIP_PATTERN)' -D $(KAJIMA_BUS_DIR) --clobber
	cd $(KAJIMA_BUS_DIR) && unzip -o $(KAJIMA_ZIP_PATTERN) && rm -f $(KAJIMA_ZIP_PATTERN)
	chmod +x $(KAJIMA_BUS_DIR)/$(KAJIMA_BIN)
	$(download_tiles)
endif

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
	openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
		-days 365 -nodes \
		-keyout $(KAJIMA_BUS_DIR)/key.pem \
		-out $(KAJIMA_BUS_DIR)/cert.pem \
		-subj "/CN=kajima-bus" \
		-addext "subjectAltName=DNS:localhost,IP:127.0.0.1,IP:$(HOST_IP)"
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
# SOURCE=1 のときは、$(KAJIMA_BUS_SRC_DIR) が既にクローンされている前提で
# git pull してから再ビルドする (未クローンならエラーで案内する) (2026-09-18 追加)。
ifeq ($(SOURCE),1)
update-webapp: check-go
	@[ -d $(KAJIMA_BUS_SRC_DIR) ] || { \
		echo ""; \
		echo "=== Error: $(KAJIMA_BUS_SRC_DIR) が見つかりません ==="; \
		echo "  先に 'make SOURCE=1 clone' を実行してください。"; \
		echo ""; \
		exit 1; \
	}
	cd $(KAJIMA_BUS_SRC_DIR) && git pull
	$(build_webapp_from_source)
	@echo ">>> $(KAJIMA_BIN) をソースから最新化しました。"
else
update-webapp: check-gh
	gh release download --repo $(KAJIMA_BUS_REPO) --pattern '$(KAJIMA_ZIP_PATTERN)' -D $(KAJIMA_BUS_DIR) --clobber
	cd $(KAJIMA_BUS_DIR) && unzip -o $(KAJIMA_ZIP_PATTERN) && rm -f $(KAJIMA_ZIP_PATTERN)
	chmod +x $(KAJIMA_BUS_DIR)/$(KAJIMA_BIN)
	$(download_tiles)
	@echo ">>> $(KAJIMA_BIN) ($(ARCH)) updated to latest release."
endif

# ===== Pull =====
ifeq ($(SOURCE),1)
pull: $(LORA_DIR) check-go
	cd $(LORA_DIR) && git pull
	@[ -d $(KAJIMA_BUS_SRC_DIR) ] || { \
		echo ""; \
		echo "=== Error: $(KAJIMA_BUS_SRC_DIR) が見つかりません ==="; \
		echo "  先に 'make SOURCE=1 clone' を実行してください。"; \
		echo ""; \
		exit 1; \
	}
	cd $(KAJIMA_BUS_SRC_DIR) && git pull
	$(build_webapp_from_source)
	@echo ">>> $(KAJIMA_BIN) をソースから最新化しました。"
else
pull: $(LORA_DIR) check-gh
	cd $(LORA_DIR) && git pull
	gh release download --repo $(KAJIMA_BUS_REPO) --pattern '$(KAJIMA_ZIP_PATTERN)' -D $(KAJIMA_BUS_DIR) --clobber
	cd $(KAJIMA_BUS_DIR) && unzip -o $(KAJIMA_ZIP_PATTERN) && rm -f $(KAJIMA_ZIP_PATTERN)
	chmod +x $(KAJIMA_BUS_DIR)/$(KAJIMA_BIN)
	$(download_tiles)
	@echo ">>> $(KAJIMA_BIN) ($(ARCH)) updated to latest release."
endif

# ===== Clean =====
clean: stop uninstall-service uninstall-portal-service
	@[ -d $(LOCAL_TTN_DIR) ] && $(MAKE) -C $(LOCAL_TTN_DIR) clean || true
	@[ -d $(LOCAL_CHIRPSTACK_DIR) ] && $(MAKE) -C $(LOCAL_CHIRPSTACK_DIR) clean || true
	sudo rm -rf $(LOCAL_TTN_DIR) $(LOCAL_CHIRPSTACK_DIR) $(KAJIMA_BUS_DIR) $(KAJIMA_BUS_SRC_DIR)
	rm -f $(BACKEND_FILE)
