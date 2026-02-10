# Repositories
LOCAL_TTN_REPO   := yuusc/local_TTN
KAJIMA_BUS_REPO  := yuusc/kajima_bus_webapp

LOCAL_TTN_DIR := local_TTN
KAJIMA_BUS_DIR := kajima_bus_webapp

# Paths (absolute)
ROOT_DIR       := $(shell pwd)
KAJIMA_BUS_ABS := $(ROOT_DIR)/$(KAJIMA_BUS_DIR)
KAJIMA_BIN     := kajima_bus_app
SERVICE_NAME   := kajima-bus-webapp

# Portal
PORTAL_DIR     := $(ROOT_DIR)/portal
PORTAL_SERVICE := portal

.PHONY: all clone build clean local_ttn kajima_bus copy-certs pull \
        start stop restart status install-service uninstall-service \
        install-portal-service uninstall-portal-service \
        check-gh check-docker download-webapp update-webapp

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
		echo "    2. リリースに '$(KAJIMA_BIN)' バイナリがアップロードされているか"; \
		echo ""; \
		exit 1; \
	}

# ===== Clone / Download =====
clone: $(LOCAL_TTN_DIR) $(KAJIMA_BUS_DIR)/$(KAJIMA_BIN)

$(LOCAL_TTN_DIR):
	gh repo clone $(LOCAL_TTN_REPO)

$(KAJIMA_BUS_DIR)/$(KAJIMA_BIN): check-gh
	mkdir -p $(KAJIMA_BUS_DIR)
	gh release download --repo $(KAJIMA_BUS_REPO) --pattern '$(KAJIMA_BIN)' -D $(KAJIMA_BUS_DIR) --clobber
	chmod +x $(KAJIMA_BUS_DIR)/$(KAJIMA_BIN)

# ===== Build =====
build: local_ttn kajima_bus

local_ttn: check-docker $(LOCAL_TTN_DIR)
	$(MAKE) -C $(LOCAL_TTN_DIR) init

copy-certs: local_ttn
	cp $(LOCAL_TTN_DIR)/certs/cert.pem $(KAJIMA_BUS_DIR)/cert.pem
	cp $(LOCAL_TTN_DIR)/certs/key.pem $(KAJIMA_BUS_DIR)/key.pem

kajima_bus: $(KAJIMA_BUS_DIR)/$(KAJIMA_BIN) copy-certs

# ===== Start / Stop =====
start: check-docker install-service install-portal-service
	$(MAKE) -C $(LOCAL_TTN_DIR) up
	sudo systemctl start $(SERVICE_NAME)
	sudo systemctl start $(PORTAL_SERVICE)
	@echo ""
	@echo "=== All services started ==="
	@echo "  TTN Stack  : make -C $(LOCAL_TTN_DIR) logs"
	@echo "  Webapp     : sudo journalctl -u $(SERVICE_NAME) -f"
	@echo "  Portal     : sudo journalctl -u $(PORTAL_SERVICE) -f"
	@echo ""

stop:
	sudo systemctl stop $(PORTAL_SERVICE) || true
	sudo systemctl stop $(SERVICE_NAME) || true
	$(MAKE) -C $(LOCAL_TTN_DIR) down

restart: stop start

status:
	$(MAKE) -C $(LOCAL_TTN_DIR) status
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
	gh release download --repo $(KAJIMA_BUS_REPO) --pattern '$(KAJIMA_BIN)' -D $(KAJIMA_BUS_DIR) --clobber
	chmod +x $(KAJIMA_BUS_DIR)/$(KAJIMA_BIN)
	@echo ">>> $(KAJIMA_BIN) updated to latest release."

# ===== Pull =====
pull: $(LOCAL_TTN_DIR) check-gh
	cd $(LOCAL_TTN_DIR) && git pull
	gh release download --repo $(KAJIMA_BUS_REPO) --pattern '$(KAJIMA_BIN)' -D $(KAJIMA_BUS_DIR) --clobber
	chmod +x $(KAJIMA_BUS_DIR)/$(KAJIMA_BIN)
	@echo ">>> $(KAJIMA_BIN) updated to latest release."

# ===== Clean =====
clean: stop uninstall-service uninstall-portal-service
	$(MAKE) -C $(LOCAL_TTN_DIR) clean || true
	sudo rm -rf $(LOCAL_TTN_DIR) $(KAJIMA_BUS_DIR)
